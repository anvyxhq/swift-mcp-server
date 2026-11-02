import Foundation
import Logging
import NIO
import NIOHTTP1

final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let mcpProtocolHandler: MCPProtocolHandler
    private let logger: Logger
    private var requestBody: ByteBuffer?
    private var responseReceived = false

    init(mcpProtocolHandler: MCPProtocolHandler, logger: Logger) {
        self.mcpProtocolHandler = mcpProtocolHandler
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let requestPart = unwrapInboundIn(data)

        switch requestPart {
        case .head(let requestHead):
            requestBody = nil
            responseReceived = false

            logger.debug("Received HTTP request: \(requestHead.method) \(requestHead.uri)")

            if requestHead.method == .OPTIONS {
                handleOptionsRequest(context: context)
                return
            }

            if requestHead.method == .GET && requestHead.uri == "/health" {
                handleHealthCheck(context: context)
                return
            }

            if requestHead.method == .GET && requestHead.uri == "/" {
                handleInfo(context: context)
                return
            }

            guard requestHead.method == .POST && (requestHead.uri == "/" || requestHead.uri == "/mcp") else {
                sendErrorResponse(context: context, status: .notFound, message: "Not Found")
                return
            }

        case .body(var byteBuffer):
            if requestBody == nil {
                requestBody = byteBuffer
            } else {
                requestBody!.writeBuffer(&byteBuffer)
            }

        case .end:
            guard !responseReceived else { return }

            guard let body = requestBody else {
                sendErrorResponse(context: context, status: .badRequest, message: "Empty request body")
                return
            }

            handleMCPRequest(context: context, body: body)
        }
    }

    private func handleOptionsRequest(context: ChannelHandlerContext) {
        guard !responseReceived else { return }
        responseReceived = true

        let headers = HTTPHeaders([
            ("Access-Control-Allow-Origin", "*"),
            ("Access-Control-Allow-Methods", "POST, OPTIONS"),
            ("Access-Control-Allow-Headers", "Content-Type"),
            ("Access-Control-Max-Age", "86400"),
        ])

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func handleMCPRequest(context: ChannelHandlerContext, body: ByteBuffer) {
        let data = Data(buffer: body)
        let promise = context.eventLoop.makePromise(of: MCPResponse.self)

        Task {
            do {
                let request = try JSONDecoder().decode(MCPRequest.self, from: data)

                do {
                    let response = try await self.mcpProtocolHandler.handleRequest(request)
                    promise.succeed(response)
                } catch let error as MCPError {
                    self.logger.error("MCP request failed: \(error)")
                    promise.succeed(MCPResponse(id: request.id, error: error))
                } catch {
                    self.logger.error("Unexpected MCP request failure: \(error)")
                    promise.succeed(MCPResponse(id: request.id, error: .internalError))
                }
            } catch {
                self.logger.error("Failed to decode MCP request: \(error)")
                promise.succeed(MCPResponse(id: self.extractRequestID(from: data), error: .parseError))
            }
        }

        promise.futureResult.whenComplete { result in
            switch result {
            case .success(let response):
                self.sendMCPResponse(context: context, response: response)
            case .failure(let error):
                self.logger.error("Failed to resolve MCP response future: \(error)")
                self.sendErrorResponse(context: context, status: .internalServerError, message: "Internal Server Error")
            }
        }
    }

    private func sendMCPResponse(context: ChannelHandlerContext, response: MCPResponse) {
        guard !responseReceived else { return }
        responseReceived = true

        do {
            let data = try JSONEncoder().encode(response)
            let buffer = context.channel.allocator.buffer(data: data)

            let headers = HTTPHeaders([
                ("Content-Type", "application/json"),
                ("Content-Length", "\(data.count)"),
                ("Access-Control-Allow-Origin", "*"),
            ])

            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)

            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        } catch {
            logger.error("Failed to encode MCP response: \(error)")
            sendErrorResponse(context: context, status: .internalServerError, message: "Failed to encode response")
        }
    }

    private func sendErrorResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        guard !responseReceived else { return }
        responseReceived = true

        let errorResponse = """
            {
                "jsonrpc": "2.0",
                "error": {
                    "code": \(status.code),
                    "message": "\(message)"
                }
            }
            """

        let data = errorResponse.data(using: .utf8)!
        let buffer = context.channel.allocator.buffer(data: data)

        let headers = HTTPHeaders([
            ("Content-Type", "application/json"),
            ("Content-Length", "\(data.count)"),
            ("Access-Control-Allow-Origin", "*"),
        ])

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    private func handleHealthCheck(context: ChannelHandlerContext) {
        let response = MCPResponse(
            id: nil,
            result: .object([
                "status": "healthy",
                "server": "Swift MCP Server",
                "version": "2.0.0",
                "timestamp": .string(ISO8601DateFormatter().string(from: Date())),
            ])
        )

        sendMCPResponse(context: context, response: response)
    }

    private func handleInfo(context: ChannelHandlerContext) {
        let response = MCPResponse(
            id: nil,
            result: .object([
                "name": "Swift MCP Server",
                "version": "2.0.0",
                "description": "A Model Context Protocol server exposing SourceKit-LSP for semantic Swift tooling",
                "capabilities": [
                    "roots": ["listChanged": true],
                    "sampling": .object([:]),
                ],
                "serverInfo": [
                    "name": "swift-mcp-server",
                    "version": "2.0.0",
                ],
            ])
        )

        sendMCPResponse(context: context, response: response)
    }

    private func extractRequestID(from data: Data) -> RequestID? {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawID = jsonObject["id"]
        else {
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

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("HTTP handler error: \(error)")
        context.close(promise: nil)
    }
}
