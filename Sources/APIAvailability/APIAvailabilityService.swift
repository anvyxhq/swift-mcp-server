import Foundation

/// Checks Swift code against a deployment target and looks up API
/// availability, using the SDKs of the active Xcode.
///
/// Availability checks type-check the file (with the rest of its module) for
/// the requested platform version, so results come from the compiler itself.
/// Lookups read the SDK's module interfaces, synthesizing them for
/// Objective-C frameworks such as UIKit.
public actor APIAvailabilityService {
    /// Modules searched when a lookup does not name any.
    public static let defaultModules = [
        "SwiftUI", "SwiftUICore", "UIKit", "Foundation", "Observation", "SwiftData", "Combine", "PhotosUI",
        "Vision", "VisionKit", "AVFoundation", "AVKit", "PDFKit", "StoreKit", "UserNotifications", "CoreLocation",
        "MapKit", "WidgetKit", "ActivityKit", "AppIntents", "Charts", "TipKit", "CoreData", "CloudKit",
        "LocalAuthentication", "Translation", "FoundationModels", "AppKit",
    ]

    private struct SDK {
        let path: String
        let version: String
    }

    private var sdks: [ApplePlatform: SDK] = [:]
    private var interfaces: [String: String] = [:]
    private let cacheDirectory: URL

    /// - Parameter cacheDirectory: where synthesized SDK interfaces and
    ///   package dependency builds are kept between runs.
    public init(cacheDirectory: URL? = nil) {
        self.cacheDirectory =
            cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("swift-mcp-server", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("swift-mcp-server", isDirectory: true)
    }

    // MARK: - Checking code

    /// The code compiled together with the checked file.
    struct CompilationUnit {
        enum Origin: Equatable {
            case package(root: URL, target: String)
            case xcodeProject(URL)
            case standalone
        }

        let moduleName: String
        var sources: [URL]
        let origin: Origin
    }

    /// Type-check `filePath` for `platform` at `minimumVersion` and report
    /// the API uses that need a newer OS or are deprecated there.
    public func check(
        filePath: String,
        minimumVersion: String,
        platform: ApplePlatform = .iOS,
        moduleFiles: [String]? = nil
    ) async throws -> AvailabilityReport {
        guard let version = normalizedVersion(minimumVersion) else {
            throw APIAvailabilityError.invalidVersion(minimumVersion)
        }
        let file = URL(fileURLWithPath: filePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw APIAvailabilityError.fileNotFound(filePath)
        }

        let sdk = try await sdk(for: platform)
        var unit = Self.compilationUnit(containing: file)
        if let moduleFiles {
            unit.sources = moduleFiles.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        if !unit.sources.contains(file) {
            unit.sources.append(file)
        }

        // Imports must resolve, or the compiler stops before checking anything.
        var searchPaths: [URL] = []
        var notes: [String] = []
        switch unit.origin {
        case .package(let root, let target):
            let build = await buildPackageDependencies(
                root: root,
                target: target,
                platform: platform,
                version: version,
                sdk: sdk
            )
            searchPaths = build.searchPaths
            notes = build.notes
        case .xcodeProject(let project):
            if let products = Self.derivedDataProducts(for: project, platform: platform) {
                searchPaths = Self.moduleDirectories(under: products)
                notes.append("Package modules come from Xcode's last build in \(products.path).")
            }
        case .standalone:
            break
        }

        let output = try await ToolRunner.run(
            "/usr/bin/xcrun",
            [
                "swiftc", "-typecheck", "-parse-as-library", "-diagnostic-style=llvm",
                "-module-name", unit.moduleName,
                "-sdk", sdk.path,
                "-target", platform.targetTriple(version: version),
            ] + searchPaths.flatMap { ["-I", $0.path, "-F", $0.path] } + unit.sources.map(\.path)
        )

        let parsed = AvailabilityDiagnosticParser.parse(output.stderr + "\n" + output.stdout, platform: platform)
        let focus = file.resolvingSymlinksInPath().path
        return AvailabilityReport(
            platform: platform,
            minimumVersion: version,
            file: filePath,
            compiledFileCount: unit.sources.count,
            issues: parsed.issues.filter { URL(fileURLWithPath: $0.file).resolvingSymlinksInPath().path == focus },
            otherErrors: parsed.otherErrors,
            missingModules: parsed.missingModules,
            notes: notes
        )
    }

    /// Run `check` for several deployment targets, lowest first.
    public func checkMatrix(
        filePath: String,
        versions: [String],
        platform: ApplePlatform = .iOS,
        moduleFiles: [String]? = nil
    ) async throws -> AvailabilityMatrix {
        var normalized: [String] = []
        for version in versions {
            guard let value = normalizedVersion(version) else {
                throw APIAvailabilityError.invalidVersion(version)
            }
            if !normalized.contains(value) {
                normalized.append(value)
            }
        }
        normalized.sort(by: versionPrecedes)

        let reports = try await withThrowingTaskGroup(of: (Int, AvailabilityReport).self) { group in
            for (index, version) in normalized.enumerated() {
                group.addTask {
                    (
                        index,
                        try await self.check(
                            filePath: filePath,
                            minimumVersion: version,
                            platform: platform,
                            moduleFiles: moduleFiles
                        )
                    )
                }
            }
            var collected: [(Int, AvailabilityReport)] = []
            for try await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        return AvailabilityMatrix(reports: reports)
    }

    /// The files compiled together with `file`: the whole SwiftPM target when
    /// the file is in one, otherwise the top-level folder of the Xcode project
    /// that contains it, otherwise just the file.
    static func compilationUnit(containing file: URL) -> CompilationUnit {
        let fileManager = FileManager.default
        var directory = file.deletingLastPathComponent()

        while directory.pathComponents.count > 1 {
            let parent = directory.deletingLastPathComponent()

            let packageRoot = parent.deletingLastPathComponent()
            if ["Sources", "Tests"].contains(parent.lastPathComponent),
                fileManager.fileExists(atPath: packageRoot.appendingPathComponent("Package.swift").path)
            {
                return CompilationUnit(
                    moduleName: moduleName(directory.lastPathComponent),
                    sources: swiftFiles(under: directory),
                    origin: .package(root: packageRoot, target: directory.lastPathComponent)
                )
            }

            let siblings = (try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? []
            if let project = siblings.first(where: { $0.hasSuffix(".xcodeproj") }) {
                return CompilationUnit(
                    moduleName: moduleName(directory.lastPathComponent),
                    sources: swiftFiles(under: directory),
                    origin: .xcodeProject(parent.appendingPathComponent(project))
                )
            }

            directory = parent
        }

        return CompilationUnit(moduleName: "AvailabilityCheck", sources: [file], origin: .standalone)
    }

    private static func moduleName(_ name: String) -> String {
        let cleaned = String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return cleaned.first?.isNumber == false ? cleaned : "_" + cleaned
    }

    /// Build the target's dependencies for the checked platform and version so
    /// its imports resolve. The target itself may fail to build (that is what
    /// is being checked); its dependencies' modules are still produced.
    private func buildPackageDependencies(
        root: URL,
        target: String,
        platform: ApplePlatform,
        version: String,
        sdk: SDK
    ) async -> (searchPaths: [URL], notes: [String]) {
        let packageKey = root.path.replacingOccurrences(of: "/", with: "_")
        let scratch =
            cacheDirectory
            .appendingPathComponent("builds", isDirectory: true)
            .appendingPathComponent(packageKey, isDirectory: true)
            .appendingPathComponent("\(platform.rawValue)-\(version)", isDirectory: true)

        let output = try? await ToolRunner.run(
            "/usr/bin/xcrun",
            [
                "swift", "build",
                "--package-path", root.path,
                "--scratch-path", scratch.path,
                "--sdk", sdk.path,
                "--triple", platform.targetTriple(version: version),
                "--target", target,
            ],
            timeout: 900
        )

        var notes: [String] = []
        if let output, output.status != 0 {
            // Errors in the checked target are reported by the type-check itself;
            // only the dependencies' failures explain a missing module.
            let targetDirectory = root.appendingPathComponent("Sources/\(target)/").path
            let log = Self.strippingTerminalColors(output.stdout + "\n" + output.stderr)
            let parsed = AvailabilityDiagnosticParser.parse(log, platform: platform)
            let dependencyIssues = parsed.issues.filter { !$0.file.hasPrefix(targetDirectory) }
            let dependencyErrors = parsed.otherErrors.filter { !$0.hasPrefix(targetDirectory) }

            if !dependencyIssues.isEmpty || !dependencyErrors.isEmpty {
                notes.append("Dependencies failed to build at \(platform.rawValue) \(version):")
                for issue in dependencyIssues.prefix(3) {
                    notes.append("  \(issue.file):\(issue.line):\(issue.column): \(issue.message)")
                }
                for error in dependencyErrors.prefix(max(0, 3 - dependencyIssues.count)) {
                    notes.append("  \(error)")
                }
            }
        } else if output == nil {
            notes.append("Could not run `swift build` for the package's dependencies.")
        }

        return (Self.moduleDirectories(under: scratch), notes)
    }

    static func strippingTerminalColors(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// Xcode's build products for `project`, from its most recently used DerivedData folder.
    private static func derivedDataProducts(for project: URL, platform: ApplePlatform) -> URL? {
        let fileManager = FileManager.default
        let derivedData = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        let prefix = project.deletingPathExtension().lastPathComponent + "-"

        let candidates =
            ((try? fileManager.contentsOfDirectory(
                at: derivedData,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []).filter { $0.lastPathComponent.hasPrefix(prefix) }

        let newest = candidates.max { lhs, rhs in
            let left =
                (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let right =
                (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return left < right
        }

        for configuration in ["Debug", "Release"] {
            let products = newest?.appendingPathComponent("Build/Products/\(configuration)-\(platform.sdkName)")
            if let products, fileManager.fileExists(atPath: products.path) {
                return products
            }
        }
        return nil
    }

    /// Directories that directly contain `.swiftmodule` or `.framework` entries.
    static func moduleDirectories(under root: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension
            guard ext == "swiftmodule" || ext == "framework" else {
                continue
            }
            enumerator.skipDescendants()
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if !directories.contains(parent) {
                directories.append(parent)
            }
        }
        return directories
    }

    private static func swiftFiles(under directory: URL, limit: Int = 3000) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url.standardizedFileURL)
            if files.count >= limit {
                break
            }
        }
        return files
    }

    // MARK: - Looking up APIs

    /// Find declarations named by `symbol` in the SDK and report their availability.
    public func lookup(
        symbol: String,
        modules: [String]? = nil,
        platform: ApplePlatform = .iOS
    ) async throws -> [APIDeclaration] {
        let sdk = try await sdk(for: platform)
        let query = SymbolQuery(symbol)
        let searchModules = modules ?? Self.defaultModules

        var texts: [(String, String)] = []
        await withTaskGroup(of: (String, String?).self) { group in
            for module in searchModules {
                group.addTask { (module, await self.interface(of: module, platform: platform, sdk: sdk)) }
            }
            for await (module, text) in group {
                if let text {
                    texts.append((module, text))
                }
            }
        }

        // Scan only interfaces that mention the name, in parallel and off the
        // actor; module interfaces run to tens of thousands of lines.
        let candidates = texts.filter { $0.1.contains(query.name) }
        let found = await withTaskGroup(of: (String, [APIDeclaration]).self) { group in
            for (module, text) in candidates {
                group.addTask {
                    (
                        module,
                        InterfaceScanner.declarations(matching: query, in: text, module: module, platform: platform)
                    )
                }
            }
            var collected: [String: [APIDeclaration]] = [:]
            for await (module, declarations) in group {
                collected[module] = declarations
            }
            return collected
        }

        // Keep results in the requested module order.
        return searchModules.flatMap { found[$0] ?? [] }
    }

    /// A module's public interface: its Swift interface plus, for modules with
    /// Objective-C headers, the synthesized Swift view of those headers.
    private func interface(of module: String, platform: ApplePlatform, sdk: SDK) async -> String? {
        let key = "\(platform.rawValue)-\(sdk.version)-\(module)"
        if let cached = interfaces[key] {
            return cached.isEmpty ? nil : cached
        }

        let cacheFile = cacheDirectory.appendingPathComponent("interfaces/\(key).swiftinterface")
        if let cached = try? String(contentsOf: cacheFile, encoding: .utf8) {
            interfaces[key] = cached
            return cached.isEmpty ? nil : cached
        }

        var text = Self.swiftInterface(of: module, platform: platform, sdkPath: sdk.path) ?? ""
        if let synthesized = await Self.synthesizedInterface(of: module, platform: platform, sdk: sdk) {
            text += "\n" + synthesized
        }

        interfaces[key] = text
        try? FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? text.write(to: cacheFile, atomically: true, encoding: .utf8)
        return text.isEmpty ? nil : text
    }

    private static func swiftInterface(of module: String, platform: ApplePlatform, sdkPath: String) -> String? {
        let fileManager = FileManager.default
        let candidates = [
            "\(sdkPath)/System/Library/Frameworks/\(module).framework/Modules/\(module).swiftmodule",
            "\(sdkPath)/usr/lib/swift/\(module).swiftmodule",
        ]

        for directory in candidates {
            guard let files = try? fileManager.contentsOfDirectory(atPath: directory) else {
                continue
            }
            let interfaceFile = files.first {
                $0.hasPrefix(platform.interfaceFilePrefix) && $0.hasSuffix(".swiftinterface")
                    && !$0.contains(".private.") && !$0.contains(".package.")
            }
            if let interfaceFile,
                let text = try? String(contentsOfFile: "\(directory)/\(interfaceFile)", encoding: .utf8)
            {
                return text
            }
        }
        return nil
    }

    private static func synthesizedInterface(of module: String, platform: ApplePlatform, sdk: SDK) async -> String? {
        let frameworkHeaders = "\(sdk.path)/System/Library/Frameworks/\(module).framework/Headers"
        guard FileManager.default.fileExists(atPath: frameworkHeaders) else {
            return nil
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-mcp-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: output) }

        guard
            let result = try? await ToolRunner.run(
                "/usr/bin/xcrun",
                [
                    "swift-synthesize-interface", "-module-name", module, "-include-submodules",
                    "-sdk", sdk.path, "-target", platform.targetTriple(version: sdk.version),
                    "-o", output.path,
                ]
            ),
            result.status == 0
        else {
            return nil
        }
        return try? String(contentsOf: output, encoding: .utf8)
    }

    // MARK: - SDK

    private func sdk(for platform: ApplePlatform) async throws -> SDK {
        if let sdk = sdks[platform] {
            return sdk
        }
        guard let path = await ToolRunner.xcrun(["--sdk", platform.sdkName, "--show-sdk-path"]),
            let version = await ToolRunner.xcrun(["--sdk", platform.sdkName, "--show-sdk-version"])
        else {
            throw APIAvailabilityError.sdkNotFound(platform)
        }
        let sdk = SDK(path: path, version: version)
        sdks[platform] = sdk
        return sdk
    }
}
