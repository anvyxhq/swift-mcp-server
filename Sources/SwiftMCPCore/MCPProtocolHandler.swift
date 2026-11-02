import Foundation
import Logging
import SourceKitLSP

public final class MCPProtocolHandler {
    private let swiftLanguageServer: SwiftLanguageServer
    private let logger: Logger

    public init(
        swiftLanguageServer: SwiftLanguageServer,
        logger: Logger
    ) {
        self.swiftLanguageServer = swiftLanguageServer
        self.logger = logger
    }

    public func handleRequest(_ request: MCPRequest) async throws -> MCPResponse {
        logger.debug("Handling MCP request: \(request.method)")

        switch request.method {
        case "initialize":
            return try await handleInitialize(request)
        case "tools/list":
            return try await handleToolsList(request)
        case "tools/call":
            return try await handleToolCall(request)
        case "resources/list":
            return try await handleResourcesList(request)
        case "resources/read":
            return try await handleResourceRead(request)
        default:
            throw MCPError.methodNotFound(request.method)
        }
    }

    // MARK: - Initialize

    private func handleInitialize(_ request: MCPRequest) async throws -> MCPResponse {
        let capabilities = ServerCapabilities(
            tools: ToolsCapability(listChanged: true),
            resources: ResourcesCapability(subscribe: true, listChanged: true)
        )

        let result = InitializeResult(
            protocolVersion: "2024-11-05",
            capabilities: capabilities,
            serverInfo: ServerInfo(
                name: "swift-mcp-server",
                version: "2.0.0"
            )
        )

        return try makeResponse(id: request.id, result: result)
    }

    // MARK: - Tools

    private func handleToolsList(_ request: MCPRequest) async throws -> MCPResponse {
        let positionSchema: JSONObject = [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "Path to the Swift file"
                ],
                "line": [
                    "type": "integer",
                    "description": "Line number (0-based)"
                ],
                "character": [
                    "type": "integer",
                    "description": "Character position (0-based)"
                ]
            ],
            "required": ["file_path", "line", "character"]
        ]

        let filePathSchema: JSONObject = [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "Path to the Swift file"
                ]
            ],
            "required": ["file_path"]
        ]

        func hierarchySchema(directions: [String], directionDescription: String) -> JSONObject {
            [
                "type": "object",
                "properties": [
                    "file_path": [
                        "type": "string",
                        "description": "Path to the Swift file"
                    ],
                    "line": [
                        "type": "integer",
                        "description": "Line number (0-based)"
                    ],
                    "character": [
                        "type": "integer",
                        "description": "Character position (0-based)"
                    ],
                    "direction": [
                        "type": "string",
                        "enum": .array(directions.map(JSONValue.string)),
                        "description": .string(directionDescription)
                    ]
                ],
                "required": ["file_path", "line", "character"]
            ]
        }

        let tools = [
            Tool(
                name: "find_symbols",
                description: "List Swift symbols declared in a file, optionally filtered by a name pattern. Backed by SourceKit-LSP.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "file_path": [
                            "type": "string",
                            "description": "Path to the Swift file"
                        ],
                        "name_pattern": [
                            "type": "string",
                            "description": "Substring to match against symbol names"
                        ]
                    ],
                    "required": ["file_path", "name_pattern"]
                ]
            ),
            Tool(
                name: "find_references",
                description: "Find all references to the symbol at a file position. Backed by SourceKit-LSP.",
                inputSchema: positionSchema
            ),
            Tool(
                name: "get_definition",
                description: "Jump to the definition of the symbol at a file position. Backed by SourceKit-LSP.",
                inputSchema: positionSchema
            ),
            Tool(
                name: "get_hover_info",
                description: "Get hover documentation and type information for the symbol at a file position. Backed by SourceKit-LSP.",
                inputSchema: positionSchema
            ),
            Tool(
                name: "format_document",
                description: "Format a Swift document and return the resulting text edits. Backed by SourceKit-LSP.",
                inputSchema: filePathSchema
            ),
            Tool(
                name: "get_diagnostics",
                description: "Get compiler diagnostics (errors and warnings) for a Swift document. Backed by SourceKit-LSP.",
                inputSchema: filePathSchema
            ),
            Tool(
                name: "search_workspace_symbols",
                description: "Search for symbols by name across the whole workspace, not just one file. Backed by SourceKit-LSP's global index.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Symbol name or substring to search for"
                        ]
                    ],
                    "required": ["query"]
                ]
            ),
            Tool(
                name: "rename_symbol",
                description: "Rename the symbol at a file position across the whole workspace and write the changes to disk. Backed by SourceKit-LSP.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "file_path": [
                            "type": "string",
                            "description": "Path to the Swift file"
                        ],
                        "line": [
                            "type": "integer",
                            "description": "Line number (0-based)"
                        ],
                        "character": [
                            "type": "integer",
                            "description": "Character position (0-based)"
                        ],
                        "new_name": [
                            "type": "string",
                            "description": "New name for the symbol"
                        ]
                    ],
                    "required": ["file_path", "line", "character", "new_name"]
                ]
            ),
            Tool(
                name: "call_hierarchy",
                description: "Find callers (incoming) or callees (outgoing) of the function at a file position. Backed by SourceKit-LSP.",
                inputSchema: hierarchySchema(
                    directions: ["incoming", "outgoing"],
                    directionDescription: "\"incoming\" for callers, \"outgoing\" for callees. Defaults to incoming."
                )
            ),
            Tool(
                name: "type_hierarchy",
                description: "Find supertypes or subtypes/conformers of the type at a file position. Backed by SourceKit-LSP.",
                inputSchema: hierarchySchema(
                    directions: ["supertypes", "subtypes"],
                    directionDescription: "\"supertypes\" for parents/protocols, \"subtypes\" for subclasses/conformers. Defaults to subtypes."
                )
            ),
            Tool(
                name: "get_implementations",
                description: "Find concrete implementations of the protocol requirement or method at a file position. Backed by SourceKit-LSP.",
                inputSchema: positionSchema
            ),
            Tool(
                name: "code_actions",
                description: "List compiler fix-its and refactorings available on a line, or apply one by title (writing the change to disk). Backed by SourceKit-LSP.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "file_path": [
                            "type": "string",
                            "description": "Path to the Swift file"
                        ],
                        "line": [
                            "type": "integer",
                            "description": "Line number (0-based)"
                        ],
                        "apply": [
                            "type": "string",
                            "description": "Optional. Title of a listed code action to apply. Omit to just list available actions."
                        ]
                    ],
                    "required": ["file_path", "line"]
                ]
            )
        ]

        return try makeResponse(id: request.id, result: ToolsListResult(tools: tools))
    }

    private func handleToolCall(_ request: MCPRequest) async throws -> MCPResponse {
        guard let params = request.params else {
            throw MCPError.invalidParams
        }

        guard let name = params.string("name") else {
            throw MCPError.invalidParams
        }

        let arguments = params.object("arguments") ?? [:]

        let result: Any
        do {
            result = try await callTool(name, arguments: arguments)
        } catch let error as MCPError {
            throw error
        } catch {
            // Tool failures (e.g. SourceKit-LSP errors) are reported as tool
            // results per the MCP spec, keeping the message for the client.
            logger.error("Tool '\(name)' failed: \(error.localizedDescription)")
            let toolResult = ToolCallResult(
                content: [
                    ToolContent(type: "text", text: "Error: \(error.localizedDescription)")
                ],
                isError: true
            )
            return try makeResponse(id: request.id, result: toolResult)
        }

        let toolResult = ToolCallResult(
            content: [
                ToolContent(type: "text", text: renderToolResult(result))
            ]
        )

        return try makeResponse(id: request.id, result: toolResult)
    }

    private func callTool(_ name: String, arguments: JSONObject) async throws -> Any {
        let result: Any

        switch name {
        case "find_symbols":
            result = try await handleFindSymbols(arguments)
        case "find_references":
            result = try await handleFindReferences(arguments)
        case "get_definition":
            result = try await handleGetDefinition(arguments)
        case "get_hover_info":
            result = try await handleGetHoverInfo(arguments)
        case "format_document":
            result = try await handleFormatDocument(arguments)
        case "get_diagnostics":
            result = try await handleGetDiagnostics(arguments)
        case "search_workspace_symbols":
            result = try await handleSearchWorkspaceSymbols(arguments)
        case "rename_symbol":
            result = try await handleRenameSymbol(arguments)
        case "call_hierarchy":
            result = try await handleCallHierarchy(arguments)
        case "type_hierarchy":
            result = try await handleTypeHierarchy(arguments)
        case "get_implementations":
            result = try await handleGetImplementations(arguments)
        case "code_actions":
            result = try await handleCodeActions(arguments)
        default:
            throw MCPError.toolNotFound(name)
        }

        return result
    }

    // MARK: - Tool Implementations

    private func handleFindSymbols(_ arguments: JSONObject) async throws -> [SymbolInfo] {
        guard let filePath = arguments.string("file_path"),
              let namePattern = arguments.string("name_pattern") else {
            throw MCPError.invalidParams
        }

        return try await swiftLanguageServer.findSymbols(in: filePath, namePattern: namePattern)
    }

    private func handleFindReferences(_ arguments: JSONObject) async throws -> [String] {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line"),
              let character = arguments.int("character") else {
            throw MCPError.invalidParams
        }

        let position = Position(line: line, character: character)
        let locations = try await swiftLanguageServer.findReferences(at: position, in: filePath)

        return locations.map { "\($0.uri):\($0.line):\($0.character)" }
    }

    private func handleGetDefinition(_ arguments: JSONObject) async throws -> [String] {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line"),
              let character = arguments.int("character") else {
            throw MCPError.invalidParams
        }

        let position = Position(line: line, character: character)
        let locations = try await swiftLanguageServer.getDefinition(at: position, in: filePath)

        return locations.map { "\($0.targetUri):\($0.targetRange.start.line):\($0.targetRange.start.character)" }
    }

    private func handleGetHoverInfo(_ arguments: JSONObject) async throws -> String {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line"),
              let character = arguments.int("character") else {
            throw MCPError.invalidParams
        }

        let position = Position(line: line, character: character)
        let hover = try await swiftLanguageServer.getHover(at: position, in: filePath)

        if case .markupContent(let content) = hover?.contents {
            return content.value
        } else if case .markedString(let string) = hover?.contents {
            return string.value
        }

        return "No hover information available"
    }

    private func handleFormatDocument(_ arguments: JSONObject) async throws -> [String] {
        guard let filePath = arguments.string("file_path") else {
            throw MCPError.invalidParams
        }

        let edits = try await swiftLanguageServer.formatDocument(at: filePath)
        return edits.map { "Line \($0.range.start.line): \($0.newText)" }
    }

    private func handleGetDiagnostics(_ arguments: JSONObject) async throws -> [String] {
        guard let filePath = arguments.string("file_path") else {
            throw MCPError.invalidParams
        }

        let diagnostics = try await swiftLanguageServer.getDiagnostics(for: filePath)
        return diagnostics.map {
            let severity = $0.severity.map { String(describing: $0).lowercased() } ?? "unknown"
            return "\($0.range.start.line):\($0.range.start.character) [\(severity)] \($0.message)"
        }
    }

    private func handleSearchWorkspaceSymbols(_ arguments: JSONObject) async throws -> [SymbolInfo] {
        guard let query = arguments.string("query") else {
            throw MCPError.invalidParams
        }

        return try await swiftLanguageServer.searchWorkspaceSymbols(query: query)
    }

    private func handleRenameSymbol(_ arguments: JSONObject) async throws -> String {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line"),
              let character = arguments.int("character"),
              let newName = arguments.string("new_name") else {
            throw MCPError.invalidParams
        }

        let position = Position(line: line, character: character)
        let edits = try await swiftLanguageServer.rename(at: position, in: filePath, newName: newName)

        guard !edits.isEmpty else {
            return "No rename edits produced. The symbol may not be renameable, or the index is not ready yet."
        }

        let totalEdits = edits.reduce(0) { $0 + $1.editCount }
        let detail = edits.map { "\($0.path) (\($0.editCount) edits)" }.joined(separator: "\n")
        return "Renamed to '\(newName)': \(totalEdits) edits across \(edits.count) file(s)\n\(detail)"
    }

    private func handleCallHierarchy(_ arguments: JSONObject) async throws -> [SymbolInfo] {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line"),
              let character = arguments.int("character") else {
            throw MCPError.invalidParams
        }

        let direction = CallHierarchyDirection(rawValue: arguments.string("direction") ?? "") ?? .incoming
        let position = Position(line: line, character: character)
        return try await swiftLanguageServer.callHierarchy(at: position, in: filePath, direction: direction)
    }

    private func handleTypeHierarchy(_ arguments: JSONObject) async throws -> [SymbolInfo] {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line"),
              let character = arguments.int("character") else {
            throw MCPError.invalidParams
        }

        let direction = TypeHierarchyDirection(rawValue: arguments.string("direction") ?? "") ?? .subtypes
        let position = Position(line: line, character: character)
        return try await swiftLanguageServer.typeHierarchy(at: position, in: filePath, direction: direction)
    }

    private func handleGetImplementations(_ arguments: JSONObject) async throws -> [String] {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line"),
              let character = arguments.int("character") else {
            throw MCPError.invalidParams
        }

        let position = Position(line: line, character: character)
        let locations = try await swiftLanguageServer.getImplementations(at: position, in: filePath)
        return locations.map { "\($0.targetUri):\($0.targetRange.start.line):\($0.targetRange.start.character)" }
    }

    private func handleCodeActions(_ arguments: JSONObject) async throws -> String {
        guard let filePath = arguments.string("file_path"),
              let line = arguments.int("line") else {
            throw MCPError.invalidParams
        }

        if let apply = arguments.string("apply") {
            let edits = try await swiftLanguageServer.applyCodeAction(titled: apply, atLine: line, in: filePath)

            guard !edits.isEmpty else {
                return "No applicable code action titled '\(apply)' at line \(line)."
            }

            let totalEdits = edits.reduce(0) { $0 + $1.editCount }
            let detail = edits.map { "\($0.path) (\($0.editCount) edits)" }.joined(separator: "\n")
            return "Applied '\(apply)': \(totalEdits) edits across \(edits.count) file(s)\n\(detail)"
        }

        let actions = try await swiftLanguageServer.codeActions(atLine: line, in: filePath)

        guard !actions.isEmpty else {
            return "No code actions available at line \(line)."
        }

        return actions.enumerated().map { index, action in
            "\(index + 1). \(action.title) [\(action.isApplicable ? "applicable" : "command-only")]"
        }.joined(separator: "\n")
    }

    // MARK: - Resources

    private func handleResourcesList(_ request: MCPRequest) async throws -> MCPResponse {
        let resources = [
            Resource(
                uri: "swift://workspace",
                name: "Swift Workspace",
                description: "Current Swift workspace information",
                mimeType: "application/json"
            )
        ]

        return try makeResponse(id: request.id, result: ResourcesListResult(resources: resources))
    }

    private func handleResourceRead(_ request: MCPRequest) async throws -> MCPResponse {
        guard let params = request.params,
              let uri = params.string("uri") else {
            throw MCPError.invalidParams
        }

        let content: String

        switch uri {
        case "swift://workspace":
            content = """
            {
                "type": "swift_workspace",
                "capabilities": ["symbol_search", "references", "definitions", "hover", "formatting", "diagnostics"],
                "sourcekit_lsp": "available"
            }
            """
        default:
            throw MCPError.resourceNotFound(uri)
        }

        let result = ResourceReadResult(
            contents: [
                ResourceContent(
                    uri: uri,
                    mimeType: "application/json",
                    text: content
                )
            ]
        )

        return try makeResponse(id: request.id, result: result)
    }

    // MARK: - Helpers

    private func makeResponse<T: Encodable>(id: RequestID?, result: T) throws -> MCPResponse {
        MCPResponse(id: id, result: try JSONValue.fromEncodable(result))
    }

    private func renderToolResult(_ result: Any) -> String {
        switch result {
        case let string as String:
            return string
        case let strings as [String]:
            return strings.isEmpty ? "No results." : strings.joined(separator: "\n")
        case let symbols as [SymbolInfo]:
            return symbols.isEmpty ? "No symbols found." : symbols.map {
                "\($0.kind) \($0.name) @ \($0.location.uri):\($0.location.line):\($0.location.character)"
            }.joined(separator: "\n")
        default:
            return String(describing: result)
        }
    }
}
