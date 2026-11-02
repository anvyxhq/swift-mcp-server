import Foundation
import Logging

actor SourceKitLSPClient {
    private struct OpenDocumentState {
        var version: Int
        var text: String
    }

    private struct PreparedDocument {
        let uri: String
    }

    /// Upper bound for waiting on index-backed requests (workspace symbols,
    /// rename, call/type hierarchy) while background indexing completes.
    private let indexReadinessTimeout: TimeInterval = 20

    private let executablePath: String
    private let workspaceRoot: URL
    private let logger: Logger

    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var stdoutBuffer = Data()
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stdoutTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private var nextRequestID = 1
    private var isStarted = false
    private var isShuttingDown = false
    private var openDocuments: [String: OpenDocumentState] = [:]
    private var latestDiagnostics: [String: [LSPDiagnostic]] = [:]
    // Raw diagnostic payloads kept verbatim so they can be replayed into a
    // codeAction request context (fix-its are matched against the original
    // diagnostic, including fields we do not decode).
    private var latestRawDiagnostics: [String: [JSONValue]] = [:]
    private var pendingRequests: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    // Keyed by URI, then by waiter, so a timed-out waiter can be removed
    // and resumed without disturbing other waiters on the same document.
    private var diagnosticWaiters: [String: [UUID: CheckedContinuation<[LSPDiagnostic], Error>]] = [:]

    init(executablePath: String, workspaceRoot: URL, logger: Logger) {
        self.executablePath = executablePath
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.logger = logger
    }

    /// Start the session, coalescing concurrent callers onto a single start
    /// operation. `performStart` suspends on the initialize round-trip, so
    /// without this guard two callers (e.g. background warm-up and the first
    /// tool call) could both pass an `isStarted` check and spawn two processes.
    func start() async throws {
        if isStarted {
            return
        }

        if let startTask {
            return try await startTask.value
        }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.performStart()
        }
        startTask = task

        do {
            try await task.value
        } catch {
            startTask = nil
            throw error
        }

        startTask = nil
    }

    private func performStart() async throws {
        guard !isStarted else { return }

        guard FileManager.default.fileExists(atPath: executablePath) else {
            throw SwiftMCPError.sourceKitNotFound
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Feed stdout through a single ordered stream so byte chunks are
        // appended in the exact order they were read. Spawning an independent
        // Task per readability callback would let the actor run them out of
        // order and corrupt LSP message framing.
        let (stdoutStream, continuation) = AsyncStream<Data>.makeStream()
        self.stdoutContinuation = continuation
        self.stdoutTask = Task { [weak self] in
            for await data in stdoutStream {
                await self?.handleStandardOutput(data)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            continuation.yield(data)
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            Task {
                await self.handleStandardError(data)
            }
        }

        process.terminationHandler = { terminatedProcess in
            Task {
                await self.handleProcessTermination(status: terminatedProcess.terminationStatus)
            }
        }

        try process.run()

        self.process = process
        self.standardInput = inputPipe.fileHandleForWriting
        self.standardOutput = outputPipe.fileHandleForReading
        self.standardError = errorPipe.fileHandleForReading

        let initializeParams: JSONObject = [
            "processId": .integer(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": [
                "name": "swift-mcp-server",
                "version": "2.0.0"
            ],
            "rootUri": .string(workspaceRoot.absoluteString),
            "capabilities": [
                "textDocument": [
                    "documentSymbol": [
                        "hierarchicalDocumentSymbolSupport": true
                    ],
                    "definition": [
                        "linkSupport": true
                    ],
                    "formatting": [:],
                    "hover": [
                        "contentFormat": ["markdown", "plaintext"]
                    ],
                    "publishDiagnostics": [:],
                    "rename": [
                        "dynamicRegistration": false
                    ],
                    "callHierarchy": [
                        "dynamicRegistration": false
                    ],
                    "typeHierarchy": [
                        "dynamicRegistration": false
                    ],
                    "codeAction": [
                        "dynamicRegistration": false,
                        "codeActionLiteralSupport": [
                            "codeActionKind": [
                                "valueSet": ["", "quickfix", "refactor", "source"]
                            ]
                        ]
                    ]
                ],
                "workspace": [
                    "workspaceFolders": true,
                    "symbol": [
                        "dynamicRegistration": false
                    ]
                ]
            ],
            "workspaceFolders": [
                [
                    "uri": .string(workspaceRoot.absoluteString),
                    "name": .string(workspaceRoot.lastPathComponent)
                ]
            ]
        ]

        _ = try await sendRequest(method: "initialize", params: initializeParams)
        try sendNotification(method: "initialized", params: [:])
        isStarted = true
        logger.info("SourceKit-LSP session started")
    }

    func documentSymbols(fileURL: URL) async throws -> [LSPSymbolInfo] {
        let document = try await prepareDocument(fileURL)
        let result = try await requestResult(
            method: "textDocument/documentSymbol",
            params: [
                "textDocument": textDocumentIdentifier(document.uri)
            ]
        )
        switch result {
        case .null:
            return []
        case .array(let values):
            return try decodeDocumentSymbols(values, fallbackURI: document.uri)
        default:
            throw SwiftMCPError.communicationError("Invalid documentSymbol payload from SourceKit-LSP")
        }
    }

    func references(fileURL: URL, position: LSPPosition, includeDeclaration: Bool = true) async throws -> [LSPLocation] {
        let document = try await prepareDocument(fileURL)

        return try await poll(
            timeout: indexReadinessTimeout,
            operation: {
                try await self.requestDecodedArray(
                    method: "textDocument/references",
                    params: self.textDocumentPositionParams(
                        uri: document.uri,
                        position: position,
                        additional: [
                            "context": [
                                "includeDeclaration": .bool(includeDeclaration)
                            ]
                        ]
                    ),
                    errorMessage: "Invalid references payload from SourceKit-LSP"
                )
            },
            until: { !$0.isEmpty }
        )
    }

    func definition(fileURL: URL, position: LSPPosition) async throws -> [LSPLocationLink] {
        let document = try await prepareDocument(fileURL)

        return try await poll(
            timeout: indexReadinessTimeout,
            operation: {
                let targets: [LSPDefinitionTarget] = try await self.requestDecodedOneOrMany(
                    method: "textDocument/definition",
                    params: self.textDocumentPositionParams(uri: document.uri, position: position),
                    errorMessage: "Invalid definition payload from SourceKit-LSP"
                )
                return targets.map(\.link)
            },
            until: { !$0.isEmpty }
        )
    }

    func hover(fileURL: URL, position: LSPPosition) async throws -> LSPHover? {
        let document = try await prepareDocument(fileURL)
        return try await requestDecodedOptionalObject(
            method: "textDocument/hover",
            params: textDocumentPositionParams(uri: document.uri, position: position),
            errorMessage: "Invalid hover payload from SourceKit-LSP"
        )
    }

    func formatDocument(fileURL: URL) async throws -> [LSPTextEdit] {
        let document = try await prepareDocument(fileURL)
        return try await requestDecodedArray(
            method: "textDocument/formatting",
            params: [
                "textDocument": textDocumentIdentifier(document.uri),
                "options": [
                    "tabSize": 4,
                    "insertSpaces": true,
                    "trimTrailingWhitespace": true,
                    "insertFinalNewline": true,
                    "trimFinalNewlines": true
                ]
            ],
            errorMessage: "Invalid formatting payload from SourceKit-LSP"
        )
    }

    func workspaceSymbols(query: String) async throws -> [LSPSymbolInfo] {
        try await start()

        return try await poll(
            timeout: indexReadinessTimeout,
            operation: {
                let result = try await self.requestResult(
                    method: "workspace/symbol",
                    params: ["query": .string(query)]
                )
                switch result {
                case .null:
                    return []
                case .array(let values):
                    return try values.map(LSPSymbolInfo.init(jsonValue:))
                default:
                    throw SwiftMCPError.communicationError("Invalid workspace/symbol payload from SourceKit-LSP")
                }
            },
            until: { !$0.isEmpty }
        )
    }

    func rename(fileURL: URL, position: LSPPosition, newName: String) async throws -> [String: [LSPTextEdit]] {
        let document = try await prepareDocument(fileURL)

        // Rename relies on the cross-reference index, which may still be
        // building right after startup; retry until edits appear or we
        // conclude the symbol simply is not renameable.
        return try await poll(
            timeout: indexReadinessTimeout,
            operation: { () async throws -> [String: [LSPTextEdit]] in
                let result = try await self.requestResult(
                    method: "textDocument/rename",
                    params: self.textDocumentPositionParams(
                        uri: document.uri,
                        position: position,
                        additional: ["newName": .string(newName)]
                    )
                )

                switch result {
                case .null:
                    return [:]
                case .object(let object):
                    return try Self.decodeWorkspaceEdit(object)
                default:
                    throw SwiftMCPError.communicationError("Invalid rename payload from SourceKit-LSP")
                }
            },
            until: { !$0.isEmpty }
        )
    }

    func callHierarchy(fileURL: URL, position: LSPPosition, incoming: Bool) async throws -> [LSPHierarchyItem] {
        let document = try await prepareDocument(fileURL)

        guard let item = try await prepareHierarchy(method: "textDocument/prepareCallHierarchy", uri: document.uri, position: position) else {
            return []
        }

        let method = incoming ? "callHierarchy/incomingCalls" : "callHierarchy/outgoingCalls"
        let key = incoming ? "from" : "to"
        let result = try await requestResult(method: method, params: ["item": item.raw])
        return try extractNestedHierarchyItems(result, key: key)
    }

    func typeHierarchy(fileURL: URL, position: LSPPosition, supertypes: Bool) async throws -> [LSPHierarchyItem] {
        let document = try await prepareDocument(fileURL)

        guard let item = try await prepareHierarchy(method: "textDocument/prepareTypeHierarchy", uri: document.uri, position: position) else {
            return []
        }

        let method = supertypes ? "typeHierarchy/supertypes" : "typeHierarchy/subtypes"
        let result = try await requestResult(method: method, params: ["item": item.raw])
        return try decodeHierarchyItems(result)
    }

    func implementations(fileURL: URL, position: LSPPosition) async throws -> [LSPLocationLink] {
        let document = try await prepareDocument(fileURL)

        return try await poll(
            timeout: indexReadinessTimeout,
            operation: {
                let targets: [LSPDefinitionTarget] = try await self.requestDecodedOneOrMany(
                    method: "textDocument/implementation",
                    params: self.textDocumentPositionParams(uri: document.uri, position: position),
                    errorMessage: "Invalid implementation payload from SourceKit-LSP"
                )
                return targets.map(\.link)
            },
            until: { !$0.isEmpty }
        )
    }

    func codeActions(fileURL: URL, line: Int) async throws -> [CodeActionResult] {
        let document = try await prepareDocument(fileURL)

        // Fix-its are matched against the original diagnostic, so replay the
        // raw diagnostics on this line verbatim into the request context.
        // Best-effort: if none have arrived we still return refactorings.
        let lineDiagnostics = await currentRawDiagnostics(uri: document.uri).filter { value in
            guard let range = value.objectValue?["range"]?.objectValue,
                  let startLine = range["start"]?.objectValue?.int("line"),
                  let endLine = range["end"]?.objectValue?.int("line") else {
                return false
            }
            return startLine <= line && line <= endLine
        }

        let params: JSONObject = [
            "textDocument": textDocumentIdentifier(document.uri),
            "range": rangeJSON(startLine: line, startCharacter: 0, endLine: line + 1, endCharacter: 0),
            "context": [
                "diagnostics": .array(lineDiagnostics)
            ]
        ]

        let result = try await requestResult(method: "textDocument/codeAction", params: params)
        return try decodeCodeActions(result)
    }

    /// Non-destructive read of the raw diagnostics for a document: returns the
    /// cached payload, otherwise waits briefly for the first publish. Never
    /// throws or hangs, so it is safe to call on every code-action request.
    private func currentRawDiagnostics(uri: String, timeout: TimeInterval = 3) async -> [JSONValue] {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if let cached = latestRawDiagnostics[uri] {
                return cached
            }

            guard Date() < deadline else {
                return []
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Prepare a call/type hierarchy item at a position, retrying while the
    /// index warms up (prepare returns an empty array until it is ready).
    private func prepareHierarchy(method: String, uri: String, position: LSPPosition) async throws -> LSPHierarchyItem? {
        let items = try await poll(
            timeout: indexReadinessTimeout,
            operation: { () async throws -> [LSPHierarchyItem] in
                let prepared = try await self.requestResult(
                    method: method,
                    params: self.textDocumentPositionParams(uri: uri, position: position)
                )
                return try self.decodeHierarchyItems(prepared)
            },
            until: { !$0.isEmpty }
        )

        return items.first
    }

    func diagnostics(fileURL: URL, timeout: TimeInterval = 5) async throws -> [LSPDiagnostic] {
        let document = try await prepareDocument(fileURL)
        latestDiagnostics.removeValue(forKey: document.uri)

        return try await waitForDiagnostics(uri: document.uri, timeout: timeout)
    }

    func shutdown() async {
        guard process != nil else { return }
        isShuttingDown = true

        if isStarted {
            _ = try? await sendRequest(method: "shutdown", params: nil)
            try? sendNotification(method: "exit", params: nil)
        }

        standardInput?.closeFile()
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        standardError?.closeFile()
        standardOutput?.closeFile()

        stdoutContinuation?.finish()
        stdoutContinuation = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        startTask?.cancel()
        startTask = nil

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
        stdoutBuffer.removeAll()
        isStarted = false
        openDocuments.removeAll()
        latestDiagnostics.removeAll()
        failAllPendingRequests(with: SwiftMCPError.communicationError("SourceKit-LSP shutdown"))
        failAllDiagnosticWaiters(with: SwiftMCPError.communicationError("SourceKit-LSP shutdown"))
    }

    // MARK: - Document Sync

    private func syncDocument(_ fileURL: URL) async throws -> Int {
        let text = try String(contentsOf: fileURL)
        let uri = fileURL.standardizedFileURL.absoluteString

        if let document = openDocuments[uri] {
            if document.text == text {
                return document.version
            }

            let nextVersion = document.version + 1
            try sendNotification(
                method: "textDocument/didChange",
                params: [
                    "textDocument": [
                        "uri": .string(uri),
                        "version": .integer(nextVersion)
                    ],
                    "contentChanges": [
                        [
                            "text": .string(text)
                        ]
                    ]
                ]
            )
            openDocuments[uri] = OpenDocumentState(version: nextVersion, text: text)
            return nextVersion
        }

        try sendNotification(
            method: "textDocument/didOpen",
            params: [
                "textDocument": [
                    "uri": .string(uri),
                    "languageId": .string(Self.languageId(for: fileURL)),
                    "version": 1,
                    "text": .string(text)
                ]
            ]
        )
        openDocuments[uri] = OpenDocumentState(version: 1, text: text)
        return 1
    }

    /// Map a file extension to an LSP languageId. SourceKit-LSP routes Swift
    /// to sourcekitd and C/Objective-C/C++ to clangd based on this, so it must
    /// be correct for mixed Swift/Objective-C projects (clangd additionally
    /// needs a compile_commands.json to resolve C-family files).
    static func languageId(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m":
            return "objective-c"
        case "mm":
            return "objective-cpp"
        case "h":
            return "objective-c"
        case "c":
            return "c"
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx":
            return "cpp"
        default:
            return "swift"
        }
    }

    // MARK: - Diagnostics

    private func waitForDiagnostics(uri: String, timeout: TimeInterval) async throws -> [LSPDiagnostic] {
        if let diagnostics = latestDiagnostics.removeValue(forKey: uri) {
            return diagnostics
        }

        // The continuation does not respond to cancellation, so the timeout
        // must remove and resume it explicitly; otherwise a document that
        // never gets a publishDiagnostics would hang the request forever.
        let waiterID = UUID()
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.timeOutDiagnosticWaiter(uri: uri, waiterID: waiterID)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            diagnosticWaiters[uri, default: [:]][waiterID] = continuation
        }
    }

    private func timeOutDiagnosticWaiter(uri: String, waiterID: UUID) {
        guard let continuation = diagnosticWaiters[uri]?.removeValue(forKey: waiterID) else {
            return
        }

        if diagnosticWaiters[uri]?.isEmpty == true {
            diagnosticWaiters.removeValue(forKey: uri)
        }

        continuation.resume(throwing: SwiftMCPError.communicationError("Timed out waiting for diagnostics from SourceKit-LSP"))
    }

    private func prepareDocument(_ fileURL: URL) async throws -> PreparedDocument {
        try await start()

        let standardizedURL = fileURL.standardizedFileURL
        _ = try await syncDocument(standardizedURL)
        return PreparedDocument(uri: standardizedURL.absoluteString)
    }

    private func poll<T>(
        timeout: TimeInterval = 5,
        interval: TimeInterval = 0.2,
        operation: () async throws -> T,
        until shouldStop: (T) -> Bool
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var lastResult = try await operation()

        while true {
            if shouldStop(lastResult) || Date() >= deadline {
                return lastResult
            }

            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            lastResult = try await operation()
        }
    }

    private func decodeDocumentSymbols(_ values: [JSONValue], fallbackURI: String) throws -> [LSPSymbolInfo] {
        guard let first = values.first else {
            return []
        }

        if first.objectValue?["selectionRange"] != nil {
            return try values
                .map(LSPDocumentSymbol.init(jsonValue:))
                .flatMap { $0.flattened(uri: fallbackURI) }
        }

        return try values.map(LSPSymbolInfo.init(jsonValue:))
    }

    private func decodeHierarchyItems(_ result: JSONValue) throws -> [LSPHierarchyItem] {
        switch result {
        case .null:
            return []
        case .array(let values):
            return try values.map(LSPHierarchyItem.init(jsonValue:))
        default:
            throw SwiftMCPError.communicationError("Invalid hierarchy payload from SourceKit-LSP")
        }
    }

    /// Incoming/outgoing call results wrap each item under a `from`/`to` key
    /// alongside `fromRanges`. Pull out the nested hierarchy item.
    private func extractNestedHierarchyItems(_ result: JSONValue, key: String) throws -> [LSPHierarchyItem] {
        switch result {
        case .null:
            return []
        case .array(let values):
            return try values.compactMap { value in
                guard let nested = value.objectValue?[key] else {
                    return nil
                }
                return try LSPHierarchyItem(jsonValue: nested)
            }
        default:
            throw SwiftMCPError.communicationError("Invalid call hierarchy payload from SourceKit-LSP")
        }
    }

    private func decodeCodeActions(_ result: JSONValue) throws -> [CodeActionResult] {
        guard case .array(let values) = result else {
            return []
        }

        return try values.compactMap { value -> CodeActionResult? in
            guard let object = value.objectValue, let title = object.string("title") else {
                return nil
            }

            let edit = try object.object("edit").map { try Self.decodeWorkspaceEdit($0) }
            return CodeActionResult(
                title: title,
                kind: object.string("kind"),
                edit: edit,
                hasCommand: object["command"] != nil
            )
        }
    }

    private func rangeJSON(startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int) -> JSONValue {
        .object([
            "start": .object(["line": .integer(startLine), "character": .integer(startCharacter)]),
            "end": .object(["line": .integer(endLine), "character": .integer(endCharacter)])
        ])
    }

    private static func decodeWorkspaceEdit(_ object: JSONObject) throws -> [String: [LSPTextEdit]] {
        var changes: [String: [LSPTextEdit]] = [:]

        if let documentChanges = object.array("documentChanges") {
            for change in documentChanges {
                guard let changeObject = change.objectValue,
                      let uri = changeObject.object("textDocument")?.string("uri"),
                      let edits = changeObject.array("edits") else {
                    continue
                }
                changes[uri, default: []].append(contentsOf: try edits.map(LSPTextEdit.init(jsonValue:)))
            }
        } else if let changeMap = object.object("changes") {
            for (uri, value) in changeMap {
                guard let edits = value.arrayValue else {
                    continue
                }
                changes[uri, default: []].append(contentsOf: try edits.map(LSPTextEdit.init(jsonValue:)))
            }
        }

        return changes
    }

    private func textDocumentIdentifier(_ uri: String) -> JSONValue {
        .object(["uri": .string(uri)])
    }

    private func textDocumentPositionParams(uri: String, position: LSPPosition, additional: JSONObject = [:]) -> JSONObject {
        var params: JSONObject = [
            "textDocument": textDocumentIdentifier(uri),
            "position": .object(position.jsonObject)
        ]

        for (key, value) in additional {
            params[key] = value
        }

        return params
    }

    /// LSP error codes that indicate the server is not yet ready to answer a
    /// semantic request (typically while SourceKit-LSP is still preparing or
    /// indexing a freshly opened document) rather than a genuine failure.
    /// These are transient and worth retrying for a short window.
    private static let transientResponseErrorCodes: Set<Int> = [
        -32002, // ServerNotInitialized
        -32603, // InternalError
        -32801, // ContentModified
        -32802, // ServerCancelled
        -32803  // RequestFailed
    ]

    private func requestResult(
        method: String,
        params: JSONObject,
        readinessTimeout: TimeInterval = 5,
        retryInterval: TimeInterval = 0.2
    ) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(readinessTimeout)

        while true {
            do {
                return try await sendRequest(method: method, params: params)
            } catch let error as SourceKitLSPClientError {
                guard case .responseError(let code, _) = error,
                      Self.transientResponseErrorCodes.contains(code),
                      Date() < deadline else {
                    throw error
                }

                logger.debug("SourceKit-LSP not ready for \(method) (code \(code)); retrying")
                try await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
            }
        }
    }

    private func requestDecodedArray<T: LSPJSONDecodable>(
        method: String,
        params: JSONObject,
        errorMessage: String
    ) async throws -> [T] {
        let result = try await requestResult(method: method, params: params)

        switch result {
        case .null:
            return []
        case .array(let values):
            return try decodeArray(values)
        default:
            throw SwiftMCPError.communicationError(errorMessage)
        }
    }

    private func requestDecodedOptionalObject<T: LSPJSONDecodable>(
        method: String,
        params: JSONObject,
        errorMessage: String
    ) async throws -> T? {
        let result = try await requestResult(method: method, params: params)

        switch result {
        case .null:
            return nil
        case .object:
            return try T(jsonValue: result)
        default:
            throw SwiftMCPError.communicationError(errorMessage)
        }
    }

    private func requestDecodedOneOrMany<T: LSPJSONDecodable>(
        method: String,
        params: JSONObject,
        errorMessage: String
    ) async throws -> [T] {
        let result = try await requestResult(method: method, params: params)

        switch result {
        case .null:
            return []
        case .object:
            return [try T(jsonValue: result)]
        case .array(let values):
            return try decodeArray(values)
        default:
            throw SwiftMCPError.communicationError(errorMessage)
        }
    }

    private func decodeArray<T: LSPJSONDecodable>(_ values: [JSONValue]) throws -> [T] {
        try values.map(T.init(jsonValue:))
    }

    // MARK: - Requests

    private func sendRequest(method: String, params: JSONObject?) async throws -> JSONValue {
        let requestID = nextRequestID
        nextRequestID += 1

        let message: JSONObject = [
            "jsonrpc": "2.0",
            "id": .integer(requestID),
            "method": .string(method),
            "params": .object(params ?? [:])
        ]

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation

            do {
                try writeMessage(message)
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: JSONObject?) throws {
        let message: JSONObject = [
            "jsonrpc": "2.0",
            "method": .string(method),
            "params": .object(params ?? [:])
        ]

        try writeMessage(message)
    }

    private func writeMessage(_ message: JSONObject) throws {
        guard let standardInput else {
            throw SwiftMCPError.communicationError("SourceKit-LSP input stream is not available")
        }

        let body = try JSONEncoder().encode(message)
        let header = Data("Content-Length: \(body.count)\r\n\r\n".utf8)

        standardInput.write(header)
        standardInput.write(body)
    }

    // MARK: - Stream Handling

    private func handleStandardOutput(_ data: Data) async {
        guard !data.isEmpty else { return }

        stdoutBuffer.append(data)
        consumeMessages()
    }

    private func handleStandardError(_ data: Data) async {
        guard !data.isEmpty,
              let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return
        }

        logger.debug("sourcekit-lsp stderr: \(message)")
    }

    private func handleProcessTermination(status: Int32) async {
        if isShuttingDown || status == 0 {
            logger.debug("SourceKit-LSP exited with status \(status)")
        } else {
            logger.warning("SourceKit-LSP exited with status \(status)")
        }
        failAllPendingRequests(with: SwiftMCPError.communicationError("SourceKit-LSP exited unexpectedly"))
        failAllDiagnosticWaiters(with: SwiftMCPError.communicationError("SourceKit-LSP exited unexpectedly"))
        stdoutContinuation?.finish()
        stdoutContinuation = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        startTask = nil
        process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
        isStarted = false
        isShuttingDown = false
    }

    private func consumeMessages() {
        while true {
            let body: Data

            do {
                guard let nextBody = try nextMessageBody() else {
                    return
                }
                body = nextBody
            } catch {
                stdoutBuffer.removeAll()
                failAllPendingRequests(with: error)
                failAllDiagnosticWaiters(with: error)
                return
            }

            do {
                let message = try JSONDecoder().decode(JSONObject.self, from: body)
                handleMessage(message)
            } catch {
                logger.error("Failed to decode SourceKit-LSP payload: \(error)")
            }
        }
    }

    private func nextMessageBody() throws -> Data? {
        let separator = Data("\r\n\r\n".utf8)

        guard let headerRange = stdoutBuffer.range(of: separator) else {
            return nil
        }

        let headerData = stdoutBuffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8),
              let contentLength = parseContentLength(headerString) else {
            throw SwiftMCPError.communicationError("Invalid LSP header from SourceKit-LSP")
        }

        let bodyStart = headerRange.upperBound
        guard stdoutBuffer.count >= bodyStart + contentLength else {
            return nil
        }

        let body = stdoutBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        stdoutBuffer.removeSubrange(0..<(bodyStart + contentLength))
        return body
    }

    private func parseContentLength(_ headerString: String) -> Int? {
        for line in headerString.components(separatedBy: "\r\n") {
            let components = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }

            if components[0].caseInsensitiveCompare("Content-Length") == .orderedSame {
                return Int(components[1].trimmingCharacters(in: .whitespaces))
            }
        }

        return nil
    }

    private func handleMessage(_ message: JSONObject) {
        if let method = message.string("method") {
            handleNotification(method: method, params: message.object("params") ?? [:])
            return
        }

        guard let requestID = parseRequestID(message["id"]) else {
            return
        }

        guard let continuation = pendingRequests.removeValue(forKey: requestID) else {
            return
        }

        if let errorObject = message.object("error") {
            let code = errorObject.int("code") ?? -1
            let message = errorObject.string("message") ?? "Unknown SourceKit-LSP error"
            continuation.resume(throwing: SourceKitLSPClientError.responseError(code: code, message: message))
            return
        }

        continuation.resume(returning: message["result"] ?? .null)
    }

    private func handleNotification(method: String, params: JSONObject) {
        guard method == "textDocument/publishDiagnostics",
              let uri = params.string("uri") else {
            return
        }

        let rawDiagnostics = params.array("diagnostics") ?? []
        latestRawDiagnostics[uri] = rawDiagnostics

        let diagnostics = rawDiagnostics.compactMap { try? LSPDiagnostic(jsonValue: $0) }

        if let waiters = diagnosticWaiters.removeValue(forKey: uri) {
            for continuation in waiters.values {
                continuation.resume(returning: diagnostics)
            }
        } else {
            latestDiagnostics[uri] = diagnostics
        }
    }

    private func parseRequestID(_ value: JSONValue?) -> Int? {
        switch value {
        case .integer(let id):
            return id
        case .string(let id):
            return Int(id)
        case .double(let id) where id.rounded() == id:
            return Int(id)
        default:
            return nil
        }
    }

    private func failAllPendingRequests(with error: Error) {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()

        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func failAllDiagnosticWaiters(with error: Error) {
        let waiters = diagnosticWaiters.values.flatMap { $0.values }
        diagnosticWaiters.removeAll()

        for continuation in waiters {
            continuation.resume(throwing: error)
        }
    }
}

private enum SourceKitLSPClientError: Error, LocalizedError {
    case responseError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .responseError(let code, let message):
            return "SourceKit-LSP error \(code): \(message)"
        }
    }
}

private protocol LSPJSONDecodable {
    init(jsonValue: JSONValue) throws
}

struct LSPTextEdit: LSPJSONDecodable {
    let range: LSPRange
    let newText: String

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue,
              let rangeValue = object["range"],
              let newText = object.string("newText") else {
            throw SwiftMCPError.communicationError("Invalid text edit payload from SourceKit-LSP")
        }

        self.range = try LSPRange(jsonValue: rangeValue)
        self.newText = newText
    }
}

struct LSPDiagnostic: LSPJSONDecodable {
    let range: LSPRange
    let severity: Int?
    let code: String?
    let source: String?
    let message: String

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue,
              let rangeValue = object["range"],
              let message = object.string("message") else {
            throw SwiftMCPError.communicationError("Invalid diagnostic payload from SourceKit-LSP")
        }

        self.range = try LSPRange(jsonValue: rangeValue)
        self.severity = object.int("severity")

        if let code = object.string("code") {
            self.code = code
        } else if let code = object.int("code") {
            self.code = String(code)
        } else {
            self.code = nil
        }

        self.source = object.string("source")
        self.message = message
    }
}

struct LSPSymbolInfo: LSPJSONDecodable {
    let name: String
    let kind: Int
    let location: LSPLocation
    let containerName: String?
    let detail: String?

    init(name: String, kind: Int, location: LSPLocation, containerName: String?, detail: String?) {
        self.name = name
        self.kind = kind
        self.location = location
        self.containerName = containerName
        self.detail = detail
    }

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue,
              let name = object.string("name"),
              let kind = object.int("kind"),
              let locationValue = object["location"] else {
            throw SwiftMCPError.communicationError("Invalid symbol payload from SourceKit-LSP")
        }

        self.name = name
        self.kind = kind
        self.location = try LSPLocation(jsonValue: locationValue)
        self.containerName = object.string("containerName")
        self.detail = object.string("detail")
    }
}

/// A code action returned by `textDocument/codeAction`. `edit` is present for
/// actions we can apply directly; `hasCommand` flags command-only actions that
/// would need a server round-trip we do not perform.
struct CodeActionResult {
    let title: String
    let kind: String?
    let edit: [String: [LSPTextEdit]]?
    let hasCommand: Bool
}

/// A call- or type-hierarchy item. `raw` preserves the original payload so it
/// can be handed back verbatim to the incomingCalls/subtypes follow-up request.
struct LSPHierarchyItem: LSPJSONDecodable {
    let raw: JSONValue
    let name: String
    let kind: Int
    let uri: String
    let selectionRange: LSPRange
    let detail: String?

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue,
              let name = object.string("name"),
              let kind = object.int("kind"),
              let uri = object.string("uri"),
              let selectionRangeValue = object["selectionRange"] else {
            throw SwiftMCPError.communicationError("Invalid hierarchy item payload from SourceKit-LSP")
        }

        self.raw = jsonValue
        self.name = name
        self.kind = kind
        self.uri = uri
        self.selectionRange = try LSPRange(jsonValue: selectionRangeValue)
        self.detail = object.string("detail")
    }
}

struct LSPDocumentSymbol: LSPJSONDecodable {
    let name: String
    let detail: String?
    let kind: Int
    let selectionRange: LSPRange
    let range: LSPRange
    let children: [LSPDocumentSymbol]

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue,
              let name = object.string("name"),
              let kind = object.int("kind"),
              let rangeValue = object["range"],
              let selectionRangeValue = object["selectionRange"] else {
            throw SwiftMCPError.communicationError("Invalid document symbol payload from SourceKit-LSP")
        }

        self.name = name
        self.detail = object.string("detail")
        self.kind = kind
        self.range = try LSPRange(jsonValue: rangeValue)
        self.selectionRange = try LSPRange(jsonValue: selectionRangeValue)
        self.children = try (object.array("children") ?? []).map(LSPDocumentSymbol.init(jsonValue:))
    }

    func flattened(uri: String, containerName: String? = nil) -> [LSPSymbolInfo] {
        let location = LSPLocation(uri: uri, range: selectionRange)
        let symbol = LSPSymbolInfo(
            name: name,
            kind: kind,
            location: location,
            containerName: containerName,
            detail: detail
        )

        return [symbol] + children.flatMap { $0.flattened(uri: uri, containerName: name) }
    }
}

struct LSPLocation: LSPJSONDecodable {
    let uri: String
    let range: LSPRange

    init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue,
              let uri = object.string("uri"),
              let rangeValue = object["range"] else {
            throw SwiftMCPError.communicationError("Invalid location payload from SourceKit-LSP")
        }

        self.uri = uri
        self.range = try LSPRange(jsonValue: rangeValue)
    }
}

struct LSPLocationLink: LSPJSONDecodable {
    let originSelectionRange: LSPRange?
    let targetUri: String
    let targetRange: LSPRange
    let targetSelectionRange: LSPRange

    init(originSelectionRange: LSPRange?, targetUri: String, targetRange: LSPRange, targetSelectionRange: LSPRange) {
        self.originSelectionRange = originSelectionRange
        self.targetUri = targetUri
        self.targetRange = targetRange
        self.targetSelectionRange = targetSelectionRange
    }

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue,
              let targetUri = object.string("targetUri"),
              let targetRangeValue = object["targetRange"],
              let targetSelectionRangeValue = object["targetSelectionRange"] else {
            throw SwiftMCPError.communicationError("Invalid location link payload from SourceKit-LSP")
        }

        self.originSelectionRange = try object["originSelectionRange"].map(LSPRange.init(jsonValue:))
        self.targetUri = targetUri
        self.targetRange = try LSPRange(jsonValue: targetRangeValue)
        self.targetSelectionRange = try LSPRange(jsonValue: targetSelectionRangeValue)
    }
}

struct LSPHover: LSPJSONDecodable {
    let markdown: String
    let range: LSPRange?

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue,
              let contents = object["contents"] else {
            throw SwiftMCPError.communicationError("Invalid hover payload from SourceKit-LSP")
        }

        self.markdown = try LSPHover.render(contents)
        self.range = try object["range"].map(LSPRange.init(jsonValue:))
    }

    private static func render(_ value: JSONValue) throws -> String {
        switch value {
        case .string(let string):
            return string
        case .array(let items):
            return try items
                .map(render)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        case .object(let object):
            if let kind = object.string("kind"),
               let markupValue = object.string("value"),
               kind == "markdown" || kind == "plaintext" {
                return markupValue
            }

            if let markedValue = object.string("value") {
                if let language = object.string("language"), !language.isEmpty {
                    return "```\(language)\n\(markedValue)\n```"
                }
                return markedValue
            }

            throw SwiftMCPError.communicationError("Invalid hover contents from SourceKit-LSP")
        default:
            throw SwiftMCPError.communicationError("Invalid hover contents from SourceKit-LSP")
        }
    }
}

struct LSPRange: LSPJSONDecodable {
    let start: LSPPosition
    let end: LSPPosition

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue,
              let startValue = object["start"],
              let endValue = object["end"] else {
            throw SwiftMCPError.communicationError("Invalid range payload from SourceKit-LSP")
        }

        self.start = try LSPPosition(jsonValue: startValue)
        self.end = try LSPPosition(jsonValue: endValue)
    }
}

struct LSPPosition: LSPJSONDecodable {
    let line: Int
    let character: Int

    init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    init(jsonValue: JSONValue) throws {
        guard let object = jsonValue.objectValue,
              let line = object.int("line"),
              let character = object.int("character") else {
            throw SwiftMCPError.communicationError("Invalid position payload from SourceKit-LSP")
        }

        self.line = line
        self.character = character
    }

    var jsonObject: JSONObject {
        [
            "line": .integer(line),
            "character": .integer(character)
        ]
    }
}

struct LSPDefinitionTarget: LSPJSONDecodable {
    let link: LSPLocationLink

    init(jsonValue: JSONValue) throws {
        if jsonValue.objectValue?["targetUri"] != nil {
            self.link = try LSPLocationLink(jsonValue: jsonValue)
            return
        }

        let location = try LSPLocation(jsonValue: jsonValue)
        self.link = LSPLocationLink(
            originSelectionRange: nil,
            targetUri: location.uri,
            targetRange: location.range,
            targetSelectionRange: location.range
        )
    }
}
