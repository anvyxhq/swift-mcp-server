import Foundation
import Logging
import SourceKitLSP

/// STDIO transport implementation for MCP protocol
/// Compatible with VS Code MCP and Serena integration
public final class StdioTransport: @unchecked Sendable {
    private let logger: Logger
    private let swiftLanguageServer: SwiftLanguageServer
    private let mcpProtocolHandler: MCPProtocolHandler
    private let shutdownLock = NSLock()
    private let stdoutLock = NSLock()
    private var hasShutdown = false

    public init(
        logger: Logger,
        workspaceRoot: URL? = nil
    ) {
        self.logger = logger
        self.swiftLanguageServer = SwiftLanguageServer(logger: logger, workspaceRoot: workspaceRoot)
        self.mcpProtocolHandler = MCPProtocolHandler(
            swiftLanguageServer: swiftLanguageServer,
            logger: logger
        )
    }

    public func start() async throws {
        logger.info("Swift MCP Server started with STDIO transport")
        logger.info("Server is ready to handle MCP requests via STDIO")

        // Warm up SourceKit-LSP in the background so the first tool call does
        // not pay the full startup and index-warmup latency.
        Task { [weak self] in
            try? await self?.swiftLanguageServer.initialize()
        }

        while true {
            guard let line = readLine() else {
                logger.debug("STDIO input closed, shutting down")
                break
            }

            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            logger.trace("Received STDIO input")

            // Handle each request in its own task so one slow SourceKit-LSP
            // call cannot block later requests or shutdown on stdin close.
            // Responses carry their request id, so they may complete out of order.
            Task { [self] in
                do {
                    // Notifications (no `id`) return nil — they must not be answered.
                    if let response = try await processRequest(line) {
                        writeToStdout(response)
                        logger.trace("Sent STDIO response")
                    }
                } catch {
                    logger.error("Error processing request: \(error)")
                    writeToStdout(createErrorResponse(error: error))
                }
            }
        }

        await shutdownIfNeeded(logMessage: "Shutting down Swift MCP Server (STDIO)...")
    }

    /// Returns the encoded response string, or `nil` when the message is a
    /// JSON-RPC notification (no `id`) — notifications are handled silently and
    /// must never receive a reply (result or error).
    private func processRequest(_ input: String) async throws -> String? {
        guard let data = input.data(using: .utf8) else {
            throw StdioError.invalidInput
        }

        let request: MCPRequest
        do {
            request = try JSONDecoder().decode(MCPRequest.self, from: data)
        } catch {
            // A parse error still warrants a response (with a null id per spec).
            logger.error("Failed to decode STDIO request: \(error)")
            return try encodeResponse(MCPResponse(id: extractRequestID(from: data), error: .parseError))
        }

        // Notifications carry no `id`; process them as no-ops and stay silent.
        guard request.id != nil else {
            logger.debug("Received notification '\(request.method)' (no response sent)")
            return nil
        }

        let response: MCPResponse
        do {
            response = try await mcpProtocolHandler.handleRequest(request)
        } catch let error as MCPError {
            response = MCPResponse(id: request.id, error: error)
        } catch {
            logger.error("Unexpected request failure: \(error)")
            response = MCPResponse(id: request.id, error: .internalError)
        }

        return try encodeResponse(response)
    }

    private func encodeResponse(_ response: MCPResponse) throws -> String {
        let responseData = try JSONEncoder().encode(response)

        guard let responseString = String(data: responseData, encoding: .utf8) else {
            throw StdioError.encodingError
        }

        return responseString
    }

    private func createErrorResponse(error: Error) -> String {
        let mcpError = (error as? MCPError) ?? .internalError
        let errorResponse = MCPResponse(id: nil, error: mcpError)

        do {
            return try encodeResponse(errorResponse)
        } catch {
            return "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
    }

    private func extractRequestID(from data: Data) -> RequestID? {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = jsonObject["id"] else {
            return nil
        }

        if let stringID = rawID as? String {
            return .string(stringID)
        }

        if let intID = rawID as? Int {
            return .number(intID)
        }

        return nil
    }

    /// Serialized so concurrent responses never interleave on stdout.
    private func writeToStdout(_ response: String) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }

        FileHandle.standardOutput.write(Data((response + "\n").utf8))
        fflush(stdout)
    }

    private func shutdownIfNeeded(logMessage: String) async {
        let shouldShutdown = markShutdownIfNeeded()
        guard shouldShutdown else {
            return
        }

        logger.info("\(logMessage)")
        await swiftLanguageServer.shutdown()
        logger.info("Swift MCP Server (STDIO) stopped")
    }

    /// Public shutdown method for external calls
    public func gracefulShutdown() async {
        await shutdownIfNeeded(logMessage: "Shutting down STDIO transport")
    }

    private func markShutdownIfNeeded() -> Bool {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }

        guard !hasShutdown else {
            return false
        }

        hasShutdown = true
        return true
    }
}

// MARK: - Error Types

enum StdioError: Error, LocalizedError {
    case invalidInput
    case encodingError

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid STDIO input format"
        case .encodingError:
            return "Failed to encode response"
        }
    }
}
