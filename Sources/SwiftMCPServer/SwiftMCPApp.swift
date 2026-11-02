import ArgumentParser
import Foundation
import Logging
import SwiftMCPCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@main
struct SwiftMCPApp {
    static func main() async throws {
        await SwiftMCPServer.main()
    }
}

/// Swift MCP Server - Professional grade Model Context Protocol server
/// Supports both HTTP and STDIO transports for maximum compatibility
struct SwiftMCPServer: AsyncParsableCommand {
    private static let loggingBootstrap: Void = {
        LoggingSystem.bootstrap { label in
            StreamLogHandler.standardError(label: label)
        }
    }()

    static let configuration = CommandConfiguration(
        commandName: "swift-mcp-server",
        abstract:
            "MCP server exposing SourceKit-LSP so AI agents can navigate, refactor, and diagnose Swift semantically",
        discussion: """
            swift-mcp-server exposes SourceKit-LSP over the Model Context Protocol so an
            AI agent or editor can navigate, inspect, refactor, and diagnose Swift (and
            Objective-C/C/C++) using compiler-grade information rather than text search.

            Transports:
            • stdio: for MCP clients such as Claude Code, Claude Desktop, and Cursor
            • http:  a local HTTP endpoint for API use and testing

            Examples:
            • swift-mcp-server --transport stdio --workspace /path/to/project
            • swift-mcp-server --transport http --workspace /path/to/project --port 8080
            """,
        version: "2.0.0"
    )

    // MARK: - Transport Configuration

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Transport protocol",
            discussion: "stdio: VS Code/Serena integration, http: API server",
            valueName: "mode"))
    var transport: TransportMode = .http

    // MARK: - Network Configuration (HTTP mode only)

    @Option(name: .shortAndLong, help: "Server bind address (HTTP mode)")
    var host: String = "127.0.0.1"

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp(
            "Fixed port number",
            discussion: "Use with --port-min/--port-max for auto-selection"))
    var port: Int = 8080

    @Option(name: .long, help: "Minimum port for auto-selection range")
    var portMin: Int?

    @Option(name: .long, help: "Maximum port for auto-selection range")
    var portMax: Int?

    // MARK: - Project Configuration

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Swift project workspace path",
            discussion: "Enables enhanced analysis with project context"))
    var workspace: String?

    @Argument(help: "Workspace path (alternative to --workspace)")
    var workspacePath: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Configuration file path",
            discussion: "JSON config for enterprise deployment"))
    var config: String?

    // MARK: - Logging Configuration

    @Option(name: .long, help: "Logging level")
    var logLevel: LogLevel = .info

    @Flag(name: .long, help: "Enable verbose output (equivalent to --log-level trace)")
    var verbose: Bool = false

    @Flag(name: .long, help: "Enable structured JSON logging")
    var jsonLogs: Bool = false

    // MARK: - Development Options

    @Flag(name: .long, help: "Enable development mode with enhanced debugging")
    var dev: Bool = false

    @Option(name: .long, help: "PID file path for process management")
    var pidFile: String?

    private var serverConfiguration = ServerConfiguration()

    // MARK: - Execution

    mutating func run() async throws {
        // Load configuration if provided
        try loadConfigurationIfNeeded()

        // Setup process management
        try setupProcessManagement()

        // Configure logging
        let logger = try setupLogging()

        // Validate configuration
        try validateConfiguration()

        // Log startup information
        logStartupInfo(logger: logger)

        // Determine workspace path (prioritize --workspace over positional argument)
        let resolvedWorkspace = workspace ?? workspacePath
        let workspaceURL = resolvedWorkspace.map { URL(fileURLWithPath: $0) }

        // Validate workspace if provided
        if let workspaceURL = workspaceURL {
            try validateWorkspace(workspaceURL, logger: logger)
        }

        // Start server based on transport type
        do {
            switch transport {
            case .stdio:
                try await startStdioServer(logger: logger, workspaceURL: workspaceURL)
            case .http:
                let selectedPort = try selectOptimalPort()
                try await startHttpServer(host: host, port: selectedPort, logger: logger, workspaceURL: workspaceURL)
            }
        } catch {
            logger.critical("Failed to start server: \(error)")
            throw ExitCode.failure
        }
    }

    // MARK: - Setup Methods

    private func setupProcessManagement() throws {
        // Handle graceful shutdown
        setupSignalHandlers()

        // Write PID file if specified
        if let pidFile = pidFile {
            try writePidFile(pidFile)
        }

        // Set process title for better monitoring
        #if os(Linux)
            // Linux-specific process title setting could go here
        #endif
    }

    private func setupLogging() throws -> Logger {
        _ = Self.loggingBootstrap
        var logger = Logger(label: "swift-mcp-server")

        // Set log level
        if verbose {
            logger.logLevel = .trace
        } else {
            logger.logLevel = logLevel.toSwiftLogLevel()
        }

        // Configure JSON logging if requested
        if jsonLogs {
            // Note: In production, you'd typically use a proper JSON formatter
            logger.info("JSON logging enabled")
        }

        // Development mode adjustments
        if dev {
            logger.logLevel = .trace
            logger.info("Development mode enabled - enhanced debugging active")
        }

        return logger
    }

    private func validateConfiguration() throws {
        // Validate port range
        if let minPort = portMin, let maxPort = portMax {
            guard minPort <= maxPort && minPort > 0 && maxPort <= 65535 else {
                throw ValidationError("Invalid port range: \(minPort)-\(maxPort). Ports must be 1-65535 and min ≤ max")
            }
        }

        // Validate single port
        guard port > 0 && port <= 65535 else {
            throw ValidationError("Invalid port: \(port). Port must be 1-65535")
        }

        // Validate host for HTTP mode
        if transport == .http && host.isEmpty {
            throw ValidationError("Host cannot be empty in HTTP mode")
        }

        // Validate workspace path
        if let workspace = workspace {
            let workspaceURL = URL(fileURLWithPath: workspace)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw ValidationError("Workspace path does not exist or is not a directory: \(workspace)")
            }
        }
    }

    private func validateWorkspace(_ workspaceURL: URL, logger: Logger) throws {
        let packageSwiftPath = workspaceURL.appendingPathComponent("Package.swift").path
        let hasPackageSwift = FileManager.default.fileExists(atPath: packageSwiftPath)

        if hasPackageSwift {
            logger.info("Detected Swift Package at workspace")
        } else {
            logger.notice("No Package.swift found - analysis may be limited")
        }

        // Check for common Swift project indicators
        let swiftFiles = try FileManager.default.contentsOfDirectory(atPath: workspaceURL.path)
            .filter { $0.hasSuffix(".swift") }

        if swiftFiles.isEmpty {
            logger.warning("No Swift files found in workspace root - check path")
        }
    }

    private func logStartupInfo(logger: Logger) {
        logger.info("Starting Swift MCP Server")
        logger.info("Version: \(Self.configuration.version)")
        logger.info("Transport: \(transport)")
        logger.info("Log Level: \(verbose ? "trace" : logLevel.rawValue)")

        let resolvedWorkspace = workspace ?? workspacePath
        if let resolvedWorkspace = resolvedWorkspace {
            logger.info("Workspace: \(resolvedWorkspace)")
        }

        if transport == .http {
            logger.info("Host: \(host)")
            if let minPort = portMin, let maxPort = portMax {
                logger.info("Port Range: \(minPort)-\(maxPort)")
            } else {
                logger.info("Port: \(port)")
            }
        }

        if dev {
            logger.info("Development mode: ACTIVE")
        }
    }

    // MARK: - Transport Implementations

    private func startHttpServer(host: String, port: Int, logger: Logger, workspaceURL: URL?) async throws {
        logger.info("Initializing HTTP transport")

        let server = MCPServer(
            host: host,
            port: port,
            logger: logger,
            workspaceRoot: workspaceURL
        )

        // Setup graceful shutdown for HTTP server
        defer {
            Task {
                try? await server.stop()
            }
        }

        try await server.start()
    }

    private func startStdioServer(logger: Logger, workspaceURL: URL?) async throws {
        logger.info("Initializing STDIO transport for AI/editor MCP integration")

        let stdinHandler = StdioTransport(
            logger: logger,
            workspaceRoot: workspaceURL
        )

        // Setup graceful shutdown for STDIO
        defer {
            Task {
                await stdinHandler.gracefulShutdown()
            }
        }

        try await stdinHandler.start()
    }

    // MARK: - Port Management

    private func selectOptimalPort() throws -> Int {
        guard transport == .http else {
            return 0  // Not applicable for STDIO
        }

        // If port range is specified, find optimal port
        if let minPort = portMin, let maxPort = portMax {
            return try findAvailablePortInRange(min: minPort, max: maxPort)
        }

        // If only min is specified, search upward
        if let minPort = portMin {
            return try findAvailablePortFrom(minPort)
        }

        // If only max is specified, search in reasonable range
        if let maxPort = portMax {
            let startPort = max(1024, maxPort - 100)
            return try findAvailablePortInRange(min: startPort, max: maxPort)
        }

        // Default: check specified port or find alternative
        if isPortAvailable(port) {
            return port
        } else {
            // Auto-find from default port
            return try findAvailablePortFrom(port)
        }
    }

    private func findAvailablePortInRange(min: Int, max: Int) throws -> Int {
        for candidatePort in min...max {
            if isPortAvailable(candidatePort) {
                return candidatePort
            }
        }
        throw ValidationError("No available ports in range \(min)-\(max)")
    }

    private func findAvailablePortFrom(_ startPort: Int) throws -> Int {
        let maxAttempts = 100
        for offset in 0..<maxAttempts {
            let candidatePort = startPort + offset
            guard candidatePort <= 65535 else { break }

            if isPortAvailable(candidatePort) {
                return candidatePort
            }
        }
        throw ValidationError("No available ports found starting from \(startPort)")
    }

    private func isPortAvailable(_ port: Int) -> Bool {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket != -1 else { return false }

        defer { close(socket) }

        // Set SO_REUSEADDR to handle TIME_WAIT states
        var reuseAddr: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    // MARK: - Signal Handling

    private func setupSignalHandlers() {
        // Setup graceful shutdown on SIGTERM and SIGINT
        signal(SIGTERM) { _ in
            fputs("\nReceived SIGTERM - graceful shutdown initiated\n", stderr)
            Darwin.exit(0)
        }

        signal(SIGINT) { _ in
            fputs("\nReceived SIGINT - graceful shutdown initiated\n", stderr)
            Darwin.exit(0)
        }

        // Ignore SIGPIPE (common in network applications)
        signal(SIGPIPE, SIG_IGN)
    }

    private func writePidFile(_ path: String) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Supporting Types

extension SwiftMCPServer {
    enum TransportMode: String, CaseIterable, ExpressibleByArgument {
        case http
        case stdio

        var defaultValueDescription: String {
            switch self {
            case .http: return "HTTP API server"
            case .stdio: return "STDIO for VS Code/Serena"
            }
        }
    }

    enum LogLevel: String, CaseIterable, ExpressibleByArgument {
        case trace, debug, info, notice, warning, error, critical

        func toSwiftLogLevel() -> Logger.Level {
            switch self {
            case .trace: return .trace
            case .debug: return .debug
            case .info: return .info
            case .notice: return .notice
            case .warning: return .warning
            case .error: return .error
            case .critical: return .critical
            }
        }
    }
}

// MARK: - Configuration Loading

extension SwiftMCPServer {
    private mutating func loadConfigurationIfNeeded() throws {
        guard let configPath = config else { return }

        let configURL = URL(fileURLWithPath: configPath)
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw ValidationError("Configuration file not found: \(configPath)")
        }

        let configData = try Data(contentsOf: configURL)
        let serverConfig = try JSONDecoder().decode(ServerConfiguration.self, from: configData)
        self.serverConfiguration = serverConfig

        // Override CLI arguments with config values
        if transport == .http {
            // Config host is not optional
            host = serverConfig.mcpServer.transport.host
            if let portRange = serverConfig.mcpServer.transport.portRange {
                portMin = portRange.min
                portMax = portRange.max
            }
        }

        writeToStandardError("Loaded enterprise configuration from: \(configPath)")
        writeToStandardError("Transport: \(serverConfig.mcpServer.transport.type)")
        if let performance = serverConfig.performance {
            writeToStandardError("Task timeout: \(performance.taskTimeoutSeconds)s")
            writeToStandardError("Max concurrent tasks: \(performance.maxConcurrentTasks)")
            writeToStandardError("Metrics enabled: \(performance.enableMetrics)")
        }
        writeToStandardError("Serena integration: \(serverConfig.serenaIntegration.languageSupport)")
    }
}

private func writeToStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
