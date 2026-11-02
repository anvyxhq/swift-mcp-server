import Foundation
import Logging

/// Swift Language Server that provides Swift language intelligence through SourceKit-LSP integration.
public final class SwiftLanguageServer {
    private static let symbolKindNames: [Int: String] = [
        1: "file",
        2: "module",
        3: "namespace",
        4: "package",
        5: "class",
        6: "method",
        7: "property",
        8: "field",
        9: "constructor",
        10: "enum",
        11: "interface",
        12: "function",
        13: "variable",
        14: "constant",
        15: "string",
        16: "number",
        17: "boolean",
        18: "array",
        19: "object",
        20: "key",
        21: "null",
        22: "enumMember",
        23: "struct",
        24: "event",
        25: "operator",
        26: "typeParameter"
    ]

    private let logger: Logger
    private let workspaceRoot: URL
    private let sourceKitLSPPath: String
    private let sourceKitLSPClient: SourceKitLSPClient

    /// The workspace root URL
    public var workspaceURL: URL {
        workspaceRoot
    }

    public init(logger: Logger, workspaceRoot: URL? = nil) {
        self.logger = logger
        self.workspaceRoot = (workspaceRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        self.sourceKitLSPPath = Self.findSourceKitLSP() ?? "/usr/bin/sourcekit-lsp"
        self.sourceKitLSPClient = SourceKitLSPClient(
            executablePath: self.sourceKitLSPPath,
            workspaceRoot: self.workspaceRoot,
            logger: logger
        )

        logger.info("Swift Language Server initialized")
        logger.info("Workspace: \(self.workspaceRoot.path)")
        logger.info("SourceKit-LSP: \(self.sourceKitLSPPath)")
        if let version = Self.toolchainVersion(forSourceKitLSP: sourceKitLSPPath) {
            logger.info("SourceKit-LSP toolchain: \(version)")
        }
    }

    // MARK: - SourceKit-LSP Discovery

    /// Find the SourceKit-LSP executable. An explicit `SOURCEKIT_LSP_PATH`
    /// environment variable wins (for custom toolchains). Next comes the
    /// active toolchain as `xcrun` reports it (honoring `xcode-select` and
    /// `DEVELOPER_DIR`), so SourceKit-LSP matches the compiler that built the
    /// workspace; a mismatch fails with "Loading the standard library failed".
    /// Only then fall back to the common install locations.
    static func findSourceKitLSP() -> String? {
        if let override = ProcessInfo.processInfo.environment["SOURCEKIT_LSP_PATH"],
           !override.isEmpty,
           FileManager.default.fileExists(atPath: override) {
            return override
        }

        if let activePath = runTool("/usr/bin/xcrun", arguments: ["--find", "sourcekit-lsp"]),
           FileManager.default.fileExists(atPath: activePath) {
            return activePath
        }

        let commonPaths = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp",
            "/usr/local/bin/sourcekit-lsp",
            "/opt/homebrew/bin/sourcekit-lsp",
            "/usr/bin/sourcekit-lsp"
        ]

        return commonPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The `swift --version` line of the toolchain that holds `sourceKitLSPPath`,
    /// logged at startup so a toolchain mismatch is visible in the server log.
    static func toolchainVersion(forSourceKitLSP sourceKitLSPPath: String) -> String? {
        let swiftPath = URL(fileURLWithPath: sourceKitLSPPath)
            .deletingLastPathComponent()
            .appendingPathComponent("swift")
            .path
        guard FileManager.default.isExecutableFile(atPath: swiftPath) else {
            return nil
        }

        return runTool(swiftPath, arguments: ["--version"])?
            .split(separator: "\n")
            .first { $0.contains("Swift version") }
            .map(String.init)
    }

    /// Run a short-lived tool and return its trimmed standard output, or nil
    /// if it cannot be launched or exits non-zero.
    private static func runTool(_ executablePath: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        return text
    }

    // MARK: - LSP Communication

    /// Ensure the SourceKit-LSP session is running. The underlying actor
    /// guards against starting twice, so this is safe to call concurrently
    /// from multiple requests.
    public func initialize() async throws {
        try await sourceKitLSPClient.start()
    }

    // MARK: - Symbol Operations for MCP

    public func findSymbols(in filePath: String, namePattern: String) async throws -> [SymbolInfo] {
        logger.debug("Finding symbols in \(filePath) with pattern: \(namePattern)")
        return try await withInitialized {
            let normalizedPattern = namePattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let symbols = try await sourceKitLSPClient.documentSymbols(fileURL: resolveFileURL(filePath))

            return symbols
                .filter { symbol in
                    normalizedPattern.isEmpty || symbol.name.lowercased().contains(normalizedPattern)
                }
                .map(makeSymbolInfo)
                .sorted {
                    if $0.location.line == $1.location.line {
                        return $0.location.character < $1.location.character
                    }
                    return $0.location.line < $1.location.line
                }
        }
    }

    public func findReferences(at position: Position, in filePath: String) async throws -> [Location] {
        logger.debug("Finding references at \(position) in \(filePath)")
        return try await withInitialized {
            let locations = try await sourceKitLSPClient.references(
                fileURL: resolveFileURL(filePath),
                position: makeLSPPosition(position)
            )

            return locations.map(makeLocation)
        }
    }

    public func getDefinition(at position: Position, in filePath: String) async throws -> [LocationLink] {
        logger.debug("Getting definition at \(position) in \(filePath)")
        return try await withInitialized {
            let definitions = try await sourceKitLSPClient.definition(
                fileURL: resolveFileURL(filePath),
                position: makeLSPPosition(position)
            )

            return definitions.map(makeLocationLink)
        }
    }

    public func getHover(at position: Position, in filePath: String) async throws -> Hover? {
        logger.debug("Getting hover info at \(position) in \(filePath)")
        return try await withInitialized {
            guard let hover = try await sourceKitLSPClient.hover(
                fileURL: resolveFileURL(filePath),
                position: makeLSPPosition(position)
            ) else {
                return nil
            }

            return makeHover(hover)
        }
    }

    public func getDiagnostics(for filePath: String) async throws -> [Diagnostic] {
        logger.debug("Getting diagnostics for \(filePath)")
        return try await withInitialized {
            let diagnostics = try await sourceKitLSPClient.diagnostics(fileURL: resolveFileURL(filePath))
            return diagnostics.map(makeDiagnostic)
        }
    }

    public func formatDocument(at filePath: String) async throws -> [TextEdit] {
        logger.debug("Formatting document at \(filePath)")
        return try await withInitialized {
            let edits = try await sourceKitLSPClient.formatDocument(fileURL: resolveFileURL(filePath))
            return edits.map(makeTextEdit)
        }
    }

    public func searchWorkspaceSymbols(query: String) async throws -> [SymbolInfo] {
        logger.debug("Searching workspace symbols for: \(query)")
        return try await withInitialized {
            let symbols = try await sourceKitLSPClient.workspaceSymbols(query: query)
            return symbols.map(makeSymbolInfo)
        }
    }

    public func rename(at position: Position, in filePath: String, newName: String) async throws -> [AppliedEdit] {
        logger.debug("Renaming symbol at \(position) in \(filePath) to \(newName)")
        return try await withInitialized {
            let changes = try await sourceKitLSPClient.rename(
                fileURL: resolveFileURL(filePath),
                position: makeLSPPosition(position),
                newName: newName
            )
            return try applyWorkspaceEdit(changes)
        }
    }

    public func getImplementations(at position: Position, in filePath: String) async throws -> [LocationLink] {
        logger.debug("Finding implementations at \(position) in \(filePath)")
        return try await withInitialized {
            let links = try await sourceKitLSPClient.implementations(
                fileURL: resolveFileURL(filePath),
                position: makeLSPPosition(position)
            )
            return links.map(makeLocationLink)
        }
    }

    public func codeActions(atLine line: Int, in filePath: String) async throws -> [CodeAction] {
        logger.debug("Fetching code actions at line \(line) in \(filePath)")
        return try await withInitialized {
            let actions = try await sourceKitLSPClient.codeActions(fileURL: resolveFileURL(filePath), line: line)
            return actions.map { CodeAction(title: $0.title, kind: $0.kind, isApplicable: $0.edit != nil) }
        }
    }

    public func applyCodeAction(titled title: String, atLine line: Int, in filePath: String) async throws -> [AppliedEdit] {
        logger.debug("Applying code action '\(title)' at line \(line) in \(filePath)")
        return try await withInitialized {
            let actions = try await sourceKitLSPClient.codeActions(fileURL: resolveFileURL(filePath), line: line)

            guard let match = actions.first(where: { $0.title == title }), let edit = match.edit else {
                return []
            }

            return try applyWorkspaceEdit(edit)
        }
    }

    public func callHierarchy(at position: Position, in filePath: String, direction: CallHierarchyDirection) async throws -> [SymbolInfo] {
        logger.debug("Call hierarchy (\(direction)) at \(position) in \(filePath)")
        return try await withInitialized {
            let items = try await sourceKitLSPClient.callHierarchy(
                fileURL: resolveFileURL(filePath),
                position: makeLSPPosition(position),
                incoming: direction == .incoming
            )
            return items.map(makeSymbolInfo)
        }
    }

    public func typeHierarchy(at position: Position, in filePath: String, direction: TypeHierarchyDirection) async throws -> [SymbolInfo] {
        logger.debug("Type hierarchy (\(direction)) at \(position) in \(filePath)")
        return try await withInitialized {
            let items = try await sourceKitLSPClient.typeHierarchy(
                fileURL: resolveFileURL(filePath),
                position: makeLSPPosition(position),
                supertypes: direction == .supertypes
            )
            return items.map(makeSymbolInfo)
        }
    }

    public func shutdown() async {
        logger.info("Swift Language Server shutdown")
        await sourceKitLSPClient.shutdown()
    }

    // MARK: - Helpers

    private func resolveFileURL(_ filePath: String) -> URL {
        if let url = URL(string: filePath), url.isFileURL {
            return url.standardizedFileURL
        }

        if filePath.hasPrefix("/") {
            return URL(fileURLWithPath: filePath).standardizedFileURL
        }

        return workspaceRoot.appendingPathComponent(filePath).standardizedFileURL
    }

    private func withInitialized<T>(_ operation: () async throws -> T) async throws -> T {
        try await initialize()
        return try await operation()
    }

    private func makeLSPPosition(_ position: Position) -> LSPPosition {
        LSPPosition(line: position.line, character: position.character)
    }

    private func makePosition(_ position: LSPPosition) -> Position {
        Position(line: position.line, character: position.character)
    }

    private func makeRange(_ range: LSPRange) -> Range {
        Range(start: makePosition(range.start), end: makePosition(range.end))
    }

    private func makeLocation(_ location: LSPLocation) -> Location {
        Location(
            uri: location.uri,
            line: location.range.start.line,
            character: location.range.start.character
        )
    }

    private func makeSymbolInfo(_ symbol: LSPSymbolInfo) -> SymbolInfo {
        SymbolInfo(
            name: symbol.name,
            kind: symbolKindName(symbol.kind),
            location: makeLocation(symbol.location),
            containerName: symbol.containerName,
            detail: symbol.detail
        )
    }

    private func makeSymbolInfo(_ item: LSPHierarchyItem) -> SymbolInfo {
        SymbolInfo(
            name: item.name,
            kind: symbolKindName(item.kind),
            location: Location(
                uri: item.uri,
                line: item.selectionRange.start.line,
                character: item.selectionRange.start.character
            ),
            containerName: nil,
            detail: item.detail
        )
    }

    /// Apply a WorkspaceEdit (from rename or a code action) to disk and report
    /// the files touched.
    private func applyWorkspaceEdit(_ changes: [String: [LSPTextEdit]]) throws -> [AppliedEdit] {
        // SourceKit-LSP can return the same file under aliased URIs (e.g.
        // /tmp vs /private/tmp on macOS). Collapse to the canonical path and
        // dedupe identical edits so each file is rewritten exactly once.
        var editsByPath: [String: [LSPTextEdit]] = [:]

        for (uri, edits) in changes {
            guard let url = URL(string: uri), url.isFileURL else { continue }

            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            editsByPath[path, default: []].append(contentsOf: edits)
        }

        var results: [AppliedEdit] = []

        for (path, edits) in editsByPath {
            let uniqueEdits = dedupeTextEdits(edits)
            let url = URL(fileURLWithPath: path)
            let original = try String(contentsOf: url, encoding: .utf8)
            let updated = applyTextEdits(uniqueEdits, to: original)

            if updated != original {
                try updated.write(to: url, atomically: true, encoding: .utf8)
            }

            results.append(AppliedEdit(path: path, editCount: uniqueEdits.count))
        }

        return results.sorted { $0.path < $1.path }
    }

    private func dedupeTextEdits(_ edits: [LSPTextEdit]) -> [LSPTextEdit] {
        var seen = Set<String>()

        return edits.filter { edit in
            let key = "\(edit.range.start.line):\(edit.range.start.character)-\(edit.range.end.line):\(edit.range.end.character)=\(edit.newText)"
            return seen.insert(key).inserted
        }
    }

    /// Apply LSP text edits to a string. Character offsets are UTF-16 code
    /// units per the LSP spec; edits are applied from the end backwards so
    /// earlier offsets stay valid.
    private func applyTextEdits(_ edits: [LSPTextEdit], to content: String) -> String {
        let units = Array(content.utf16)

        // Precompute the UTF-16 offset where each line begins so position
        // lookups are O(1) instead of rescanning the whole file per edit.
        var lineStarts = [0]
        for index in units.indices where units[index] == 10 {
            lineStarts.append(index + 1)
        }

        func offset(line: Int, character: Int) -> Int {
            guard line >= 0, line < lineStarts.count else {
                return units.count
            }
            return min(lineStarts[line] + character, units.count)
        }

        let ordered = edits.sorted { lhs, rhs in
            offset(line: lhs.range.start.line, character: lhs.range.start.character) >
                offset(line: rhs.range.start.line, character: rhs.range.start.character)
        }

        var result = units

        for edit in ordered {
            let start = offset(line: edit.range.start.line, character: edit.range.start.character)
            let end = offset(line: edit.range.end.line, character: edit.range.end.character)

            guard start <= end, end <= result.count else { continue }

            result.replaceSubrange(start..<end, with: Array(edit.newText.utf16))
        }

        return String(decoding: result, as: UTF16.self)
    }

    private func makeLocationLink(_ link: LSPLocationLink) -> LocationLink {
        LocationLink(
            originSelectionRange: link.originSelectionRange.map(makeRange),
            targetUri: link.targetUri,
            targetRange: makeRange(link.targetRange),
            targetSelectionRange: makeRange(link.targetSelectionRange)
        )
    }

    private func makeHover(_ hover: LSPHover) -> Hover {
        Hover(
            contents: .markupContent(
                MarkupContent(
                    kind: "markdown",
                    value: hover.markdown
                )
            ),
            range: hover.range.map(makeRange)
        )
    }

    private func makeDiagnostic(_ diagnostic: LSPDiagnostic) -> Diagnostic {
        Diagnostic(
            range: makeRange(diagnostic.range),
            severity: diagnostic.severity.flatMap(DiagnosticSeverity.init(rawValue:)),
            code: diagnostic.code,
            source: diagnostic.source,
            message: diagnostic.message
        )
    }

    private func makeTextEdit(_ edit: LSPTextEdit) -> TextEdit {
        TextEdit(
            range: makeRange(edit.range),
            newText: edit.newText
        )
    }

    private func symbolKindName(_ rawValue: Int) -> String {
        Self.symbolKindNames[rawValue] ?? "unknown"
    }
}

// MARK: - Supporting Types

public enum CallHierarchyDirection: String {
    case incoming
    case outgoing
}

public enum TypeHierarchyDirection: String {
    case supertypes
    case subtypes
}

public struct AppliedEdit {
    public let path: String
    public let editCount: Int

    public init(path: String, editCount: Int) {
        self.path = path
        self.editCount = editCount
    }
}

public struct CodeAction {
    public let title: String
    public let kind: String?
    public let isApplicable: Bool

    public init(title: String, kind: String?, isApplicable: Bool) {
        self.title = title
        self.kind = kind
        self.isApplicable = isApplicable
    }
}

public struct SymbolInfo {
    public let name: String
    public let kind: String
    public let location: Location
    public let containerName: String?
    public let detail: String?

    public init(name: String, kind: String, location: Location, containerName: String?, detail: String? = nil) {
        self.name = name
        self.kind = kind
        self.location = location
        self.containerName = containerName
        self.detail = detail
    }
}

public struct Location {
    public let uri: String
    public let line: Int
    public let character: Int

    public init(uri: String, line: Int, character: Int) {
        self.uri = uri
        self.line = line
        self.character = character
    }
}

public struct Position {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct Range {
    public let start: Position
    public let end: Position

    public init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }
}

public struct LocationLink {
    public let originSelectionRange: Range?
    public let targetUri: String
    public let targetRange: Range
    public let targetSelectionRange: Range

    public init(originSelectionRange: Range?, targetUri: String, targetRange: Range, targetSelectionRange: Range) {
        self.originSelectionRange = originSelectionRange
        self.targetUri = targetUri
        self.targetRange = targetRange
        self.targetSelectionRange = targetSelectionRange
    }
}

public struct Hover {
    public let contents: HoverContent
    public let range: Range?

    public init(contents: HoverContent, range: Range?) {
        self.contents = contents
        self.range = range
    }
}

public enum HoverContent {
    case markupContent(MarkupContent)
    case markedString(MarkedString)
}

public struct MarkupContent {
    public let kind: String
    public let value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct MarkedString {
    public let language: String?
    public let value: String

    public init(language: String?, value: String) {
        self.language = language
        self.value = value
    }
}

public struct TextEdit {
    public let range: Range
    public let newText: String

    public init(range: Range, newText: String) {
        self.range = range
        self.newText = newText
    }
}

public struct Diagnostic {
    public let range: Range
    public let severity: DiagnosticSeverity?
    public let code: String?
    public let source: String?
    public let message: String

    public init(range: Range, severity: DiagnosticSeverity?, code: String?, source: String?, message: String) {
        self.range = range
        self.severity = severity
        self.code = code
        self.source = source
        self.message = message
    }
}

public enum DiagnosticSeverity: Int {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

public enum SwiftMCPError: Error, LocalizedError {
    case sourceKitNotFound
    case lspNotInitialized
    case symbolSearchFailed(Error)
    case referenceSearchFailed(Error)
    case definitionSearchFailed(Error)
    case hoverFailed(Error)
    case formattingFailed(Error)
    case communicationError(String)

    public var errorDescription: String? {
        switch self {
        case .sourceKitNotFound:
            return "SourceKit-LSP executable not found on system"
        case .lspNotInitialized:
            return "Language server not initialized. Call initialize() first."
        case .symbolSearchFailed(let error):
            return "Symbol search failed: \(error.localizedDescription)"
        case .referenceSearchFailed(let error):
            return "Reference search failed: \(error.localizedDescription)"
        case .definitionSearchFailed(let error):
            return "Definition search failed: \(error.localizedDescription)"
        case .hoverFailed(let error):
            return "Hover request failed: \(error.localizedDescription)"
        case .formattingFailed(let error):
            return "Code formatting failed: \(error.localizedDescription)"
        case .communicationError(let message):
            return "LSP communication error: \(message)"
        }
    }
}
