import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import SourceKitLSP

public final class MCPServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let logger: Logger
    private let group: EventLoopGroup
    private var channel: Channel?

    private let swiftLanguageServer: SwiftLanguageServer
    private let mcpProtocolHandler: MCPProtocolHandler

    public init(
        host: String,
        port: Int,
        logger: Logger,
        workspaceRoot: URL? = nil
    ) {
        self.host = host
        self.port = port
        self.logger = logger
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        self.swiftLanguageServer = SwiftLanguageServer(logger: logger, workspaceRoot: workspaceRoot)
        self.mcpProtocolHandler = MCPProtocolHandler(
            swiftLanguageServer: swiftLanguageServer,
            logger: logger
        )
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    public func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPHandler(
                    mcpProtocolHandler: self.mcpProtocolHandler,
                    logger: self.logger
                )

                return channel.pipeline.configureHTTPServerPipeline(
                    withErrorHandling: true
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.channel = channel

        logger.info("Swift MCP Server started on \(host):\(port)")
        logger.info("Server is ready to handle MCP requests")

        // Warm up SourceKit-LSP in the background so the first tool call does
        // not pay the full startup and index-warmup latency.
        Task { [weak self] in
            try? await self?.swiftLanguageServer.initialize()
        }

        // Wait until the server is closed
        try await channel.closeFuture.get()
    }

    public func stop() async throws {
        logger.info("Shutting down Swift MCP Server...")

        await swiftLanguageServer.shutdown()
        try await channel?.close()
        try await group.shutdownGracefully()

        logger.info("Swift MCP Server stopped")
    }
}
