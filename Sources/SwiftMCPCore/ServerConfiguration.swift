import Foundation
import Logging

/// Enterprise-grade configuration management for Swift MCP Server
public struct ServerConfiguration: Codable {
    // MARK: - Transport Configuration
    public struct Transport: Codable {
        public let type: TransportType
        public let host: String
        public let port: Int
        public let portRange: PortRange?
        public let autoPortSelection: Bool
        public let httpFallback: Bool?

        public init(
            type: TransportType = .http,
            host: String = "127.0.0.1",
            port: Int = 8080,
            portRange: PortRange? = nil,
            autoPortSelection: Bool = true,
            httpFallback: Bool? = nil
        ) {
            self.type = type
            self.host = host
            self.port = port
            self.portRange = portRange
            self.autoPortSelection = autoPortSelection
            self.httpFallback = httpFallback
        }
    }

    public struct PortRange: Codable {
        public let min: Int
        public let max: Int

        public init(min: Int, max: Int) {
            self.min = min
            self.max = max
        }
    }

    public enum TransportType: String, Codable, CaseIterable {
        case http
        case stdio
    }

    // MARK: - Server Capabilities
    public struct Capabilities: Codable {
        public let tools: [String]
        public let resources: [String]
        public let experimental: ExperimentalFeatures?

        public init(
            tools: [String] = defaultTools,
            resources: [String] = defaultResources,
            experimental: ExperimentalFeatures? = ExperimentalFeatures()
        ) {
            self.tools = tools
            self.resources = resources
            self.experimental = experimental
        }

        public static let defaultTools = [
            "find_symbols", "find_references", "get_definition",
            "get_hover_info", "format_document", "get_diagnostics",
        ]

        public static let defaultResources = [
            "swift://workspace"
        ]
    }

    public struct ExperimentalFeatures: Codable {
        public let swiftLanguageSupport: Bool
        public let sourceKitLSP: Bool
        public let modernConcurrency: Bool
        public let aiCodeAnalysis: Bool

        public init(
            swiftLanguageSupport: Bool = true,
            sourceKitLSP: Bool = true,
            modernConcurrency: Bool = true,
            aiCodeAnalysis: Bool = false
        ) {
            self.swiftLanguageSupport = swiftLanguageSupport
            self.sourceKitLSP = sourceKitLSP
            self.modernConcurrency = modernConcurrency
            self.aiCodeAnalysis = aiCodeAnalysis
        }
    }

    // MARK: - Serena Integration
    public struct SerenaIntegration: Codable {
        public let languageSupport: String
        public let tools: SerenaTools

        public init(
            languageSupport: String = "swift",
            tools: SerenaTools = SerenaTools()
        ) {
            self.languageSupport = languageSupport
            self.tools = tools
        }
    }

    public struct SerenaTools: Codable {
        public let findSymbol: FindSymbolConfig
        public let findReferencingSymbols: FindReferencingSymbolsConfig
        public let symbolOperations: SymbolOperationsConfig

        public init(
            findSymbol: FindSymbolConfig = FindSymbolConfig(),
            findReferencingSymbols: FindReferencingSymbolsConfig = FindReferencingSymbolsConfig(),
            symbolOperations: SymbolOperationsConfig = SymbolOperationsConfig()
        ) {
            self.findSymbol = findSymbol
            self.findReferencingSymbols = findReferencingSymbols
            self.symbolOperations = symbolOperations
        }
    }

    public struct FindSymbolConfig: Codable {
        public let namePatterns: [String]
        public let searchTypes: [String]

        public init(
            namePatterns: [String] = ["class", "function", "method", "variable", "protocol", "enum"],
            searchTypes: [String] = ["substring", "exact", "regex"]
        ) {
            self.namePatterns = namePatterns
            self.searchTypes = searchTypes
        }
    }

    public struct FindReferencingSymbolsConfig: Codable {
        public let supportedTypes: [String]

        public init(supportedTypes: [String] = ["classes", "methods", "functions", "variables"]) {
            self.supportedTypes = supportedTypes
        }
    }

    public struct SymbolOperationsConfig: Codable {
        public let insertAfterSymbol: Bool
        public let insertBeforeSymbol: Bool
        public let replaceSymbolBody: Bool

        public init(
            insertAfterSymbol: Bool = true,
            insertBeforeSymbol: Bool = true,
            replaceSymbolBody: Bool = true
        ) {
            self.insertAfterSymbol = insertAfterSymbol
            self.insertBeforeSymbol = insertBeforeSymbol
            self.replaceSymbolBody = replaceSymbolBody
        }
    }

    // MARK: - Requirements
    public struct Requirements: Codable {
        public let swift: String
        public let macos: String
        public let sourceKitLSP: String

        public init(
            swift: String = ">=5.9",
            macos: String = ">=13.0",
            sourceKitLSP: String = ">=1.0.0"
        ) {
            self.swift = swift
            self.macos = macos
            self.sourceKitLSP = sourceKitLSP
        }
    }

    // MARK: - Performance Configuration
    public struct Performance: Codable {
        public let maxConcurrentTasks: Int
        public let taskTimeoutSeconds: TimeInterval
        public let memoryLimitMB: Int?
        public let enableMetrics: Bool

        public init(
            maxConcurrentTasks: Int = 10,
            taskTimeoutSeconds: TimeInterval = 30.0,
            memoryLimitMB: Int? = nil,
            enableMetrics: Bool = true
        ) {
            self.maxConcurrentTasks = maxConcurrentTasks
            self.taskTimeoutSeconds = taskTimeoutSeconds
            self.memoryLimitMB = memoryLimitMB
            self.enableMetrics = enableMetrics
        }
    }

    // MARK: - Main Configuration
    public let name: String
    public let version: String
    public let description: String
    public let mcpServer: MCPServerConfig
    public let serenaIntegration: SerenaIntegration
    public let requirements: Requirements
    public let performance: Performance?

    public struct MCPServerConfig: Codable {
        public let transport: Transport
        public let capabilities: Capabilities

        public init(
            transport: Transport = Transport(),
            capabilities: Capabilities = Capabilities()
        ) {
            self.transport = transport
            self.capabilities = capabilities
        }
    }

    public init(
        name: String = "swift-mcp-server",
        version: String = "2.0.0",
        description: String = "A Model Context Protocol server exposing SourceKit-LSP for semantic Swift tooling",
        mcpServer: MCPServerConfig = MCPServerConfig(),
        serenaIntegration: SerenaIntegration = SerenaIntegration(),
        requirements: Requirements = Requirements(),
        performance: Performance? = Performance()
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.mcpServer = mcpServer
        self.serenaIntegration = serenaIntegration
        self.requirements = requirements
        self.performance = performance
    }

    // MARK: - Configuration Loading

    /// Load configuration from JSON file with fallback to defaults
    public static func load(from path: String, logger: Logger? = nil) -> ServerConfiguration {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let config = try JSONDecoder().decode(ServerConfiguration.self, from: data)
            logger?.info("Configuration loaded from: \(path)")
            return config
        } catch {
            logger?.warning("Failed to load config from \(path): \(error)")
            logger?.info("Using default configuration")
            return ServerConfiguration()
        }
    }

    /// Save current configuration to JSON file
    public func save(to path: String, logger: Logger? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path))

        logger?.info("Configuration saved to: \(path)")
    }

    /// Validate configuration for consistency and requirements
    public func validate() throws {
        // Validate port range
        if let portRange = mcpServer.transport.portRange {
            guard portRange.min <= portRange.max,
                portRange.min > 0,
                portRange.max <= 65535
            else {
                throw ConfigurationError.invalidPortRange(portRange.min, portRange.max)
            }
        }

        // Validate main port
        guard mcpServer.transport.port > 0 && mcpServer.transport.port <= 65535 else {
            throw ConfigurationError.invalidPort(mcpServer.transport.port)
        }

        // Validate performance settings
        if let performance = performance {
            guard performance.maxConcurrentTasks > 0 else {
                throw ConfigurationError.invalidPerformanceConfig("maxConcurrentTasks must be > 0")
            }

            guard performance.taskTimeoutSeconds > 0 else {
                throw ConfigurationError.invalidPerformanceConfig("taskTimeoutSeconds must be > 0")
            }

            if let memoryLimit = performance.memoryLimitMB {
                guard memoryLimit > 0 else {
                    throw ConfigurationError.invalidPerformanceConfig("memoryLimitMB must be > 0")
                }
            }
        }
    }
}

// MARK: - Error Types

public enum ConfigurationError: Error, LocalizedError {
    case invalidPortRange(Int, Int)
    case invalidPort(Int)
    case invalidPerformanceConfig(String)
    case missingRequiredField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPortRange(let min, let max):
            return "Invalid port range: \(min)-\(max). Must be 1-65535 and min ≤ max"
        case .invalidPort(let port):
            return "Invalid port: \(port). Must be 1-65535"
        case .invalidPerformanceConfig(let message):
            return "Invalid performance configuration: \(message)"
        case .missingRequiredField(let field):
            return "Missing required configuration field: \(field)"
        }
    }
}
