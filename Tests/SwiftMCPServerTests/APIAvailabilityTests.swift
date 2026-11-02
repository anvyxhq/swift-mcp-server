import Foundation
import XCTest

@testable import APIAvailability

final class APIAvailabilityTests: XCTestCase {
    // MARK: - @available parsing

    func testParsesShorthandAvailability() {
        let attributes = AvailabilityAttribute.parseAll(in: "@available(iOS 15.0, macOS 12.0, *) @MainActor")

        XCTAssertEqual(
            attributes,
            [
                AvailabilityAttribute(platform: "iOS", introduced: "15.0"),
                AvailabilityAttribute(platform: "macOS", introduced: "12.0"),
            ]
        )
    }

    func testParsesLongFormAvailability() {
        let attributes = AvailabilityAttribute.parseAll(
            in: #"@available(iOS, introduced: 2.0, deprecated: 10.0, message: "Use open(_:options:), please")"#
        )

        XCTAssertEqual(attributes.count, 1)
        XCTAssertEqual(attributes[0].platform, "iOS")
        XCTAssertEqual(attributes[0].introduced, "2.0")
        XCTAssertEqual(attributes[0].deprecated, "10.0")
        XCTAssertEqual(attributes[0].message, "Use open(_:options:), please")
    }

    func testParsesUnavailableAndRenamed() {
        let attributes = AvailabilityAttribute.parseAll(
            in: #"@available(*, deprecated, renamed: "newName") @available(watchOS, unavailable)"#
        )

        XCTAssertEqual(attributes.count, 2)
        XCTAssertEqual(attributes[0].platform, "*")
        XCTAssertEqual(attributes[0].deprecated, "")
        XCTAssertEqual(attributes[0].renamed, "newName")
        XCTAssertTrue(attributes[1].isUnavailable)
    }

    // MARK: - Compiler diagnostics

    func testDiagnosticParserExtractsAvailabilityIssues() {
        let output = """
            A.swift:4:2: error: 'Observable()' is only available in iOS 17.0 or newer
            /tmp/swift-generated-sources/@__swiftmacro_1M5Model.swift:1:2: error: 'ObservationTracked()' is only available in iOS 17.0 or newer
            A.swift:4:25: note: add '@available' attribute to enclosing class
            A.swift:4:2: error: 'Observable()' is only available in iOS 17.0 or newer
            A.swift:11:10: error: 'scrollContentBackground' is only available in iOS 16.0 or newer
            A.swift:16:26: warning: 'openURL' was deprecated in iOS 10.0 [#DeprecatedDeclaration]
            A.swift:18:5: warning: 'oldThing' was deprecated in iOS 15.0: Use newThing instead
            A.swift:19:5: error: 'onlyMac' is unavailable in iOS
            A.swift:20:5: error: 'macThing' is only available in macOS 14.0 or newer
            A.swift:1:8: error: no such module 'PermissionKit'
            A.swift:21:13: error: cannot find 'Helper' in scope
            """

        let result = AvailabilityDiagnosticParser.parse(output, platform: .iOS)

        XCTAssertEqual(
            result.issues.map(\.kind),
            [
                .requiresNewer(version: "17.0"),
                .requiresNewer(version: "16.0"),
                .deprecated(version: "10.0", message: nil),
                .deprecated(version: "15.0", message: "Use newThing instead"),
                .unavailable(message: nil),
            ]
        )
        XCTAssertEqual(
            result.issues.map(\.symbol), ["Observable()", "scrollContentBackground", "openURL", "oldThing", "onlyMac"])
        XCTAssertEqual(result.issues.first?.line, 4)
        XCTAssertEqual(result.missingModules, ["PermissionKit"])
        XCTAssertEqual(result.otherErrors.count, 2)  // macOS-only API and the unresolved type
    }

    func testReportSummarizesHighestRequiredVersion() {
        let report = AvailabilityReport(
            platform: .iOS,
            minimumVersion: "15.0",
            file: "A.swift",
            compiledFileCount: 1,
            issues: [
                AvailabilityIssue(
                    file: "A.swift", line: 1, column: 1, symbol: "a", kind: .requiresNewer(version: "16.4"), message: ""
                ),
                AvailabilityIssue(
                    file: "A.swift", line: 2, column: 1, symbol: "b", kind: .requiresNewer(version: "17.0"), message: ""
                ),
                AvailabilityIssue(
                    file: "A.swift", line: 3, column: 1, symbol: "c", kind: .deprecated(version: "13.0", message: nil),
                    message: ""),
            ],
            otherErrors: [],
            missingModules: []
        )

        XCTAssertEqual(report.highestRequiredVersion, "17.0")
        XCTAssertEqual(report.blockingIssues.count, 2)
        XCTAssertEqual(report.deprecations.count, 1)
        XCTAssertTrue(report.summary.contains("raise the deployment target to iOS 17.0"), report.summary)
    }

    func testVersionHelpers() {
        XCTAssertEqual(normalizedVersion("15"), "15.0")
        XCTAssertEqual(normalizedVersion("16.4"), "16.4")
        XCTAssertNil(normalizedVersion("latest"))
        XCTAssertTrue(versionPrecedes("9.0", "10.0"))
        XCTAssertFalse(versionPrecedes("17.0", "17"))
        XCTAssertEqual(ApplePlatform(name: "xros"), .visionOS)
    }

    // MARK: - Interface scanning

    private let sampleInterface = """
        @available(iOS 15.0, *)
        @MainActor open class UISheetPresentationController : UIPresentationController {
            open var detents: [UISheetPresentationController.Detent]
            @available(iOS 16.0, *)
            open func animateChanges(_ changes: () -> Void)
        }
        extension UIApplication {
            @available(iOS, introduced: 2.0, deprecated: 10.0, message: "Please use openURL:options:completionHandler: instead")
            open func openURL(_ url: URL) -> Bool
            @available(iOS 10.0, *)
            open func open(_ url: URL, options: [String : Any] = [:], completionHandler completion: ((Bool) -> Void)? = nil)
        }
        """

    func testMembersInheritEnclosingTypeAvailability() throws {
        let detents = InterfaceScanner.declarations(
            matching: SymbolQuery("UISheetPresentationController.detents"),
            in: sampleInterface,
            module: "UIKit",
            platform: .iOS
        )
        let declaration = try XCTUnwrap(detents.first)
        XCTAssertEqual(detents.count, 1)
        XCTAssertEqual(declaration.availability.introduced, "15.0")
        XCTAssertEqual(declaration.availability.inheritedFrom, "UISheetPresentationController")

        let animate = InterfaceScanner.declarations(
            matching: SymbolQuery("animateChanges"),
            in: sampleInterface,
            module: "UIKit",
            platform: .iOS
        )
        XCTAssertEqual(animate.first?.availability.introduced, "16.0")
        XCTAssertNil(animate.first?.availability.inheritedFrom)
    }

    func testLookupReportsDeprecationAndMatchesLabels() throws {
        let deprecated = try XCTUnwrap(
            InterfaceScanner.declarations(
                matching: SymbolQuery("UIApplication.openURL"),
                in: sampleInterface,
                module: "UIKit",
                platform: .iOS
            ).first
        )
        XCTAssertEqual(deprecated.availability.deprecated, "10.0")
        XCTAssertEqual(deprecated.enclosingType, "UIApplication")
        XCTAssertTrue(deprecated.availability.describe(platform: .iOS).contains("deprecated in iOS 10.0"))

        let withLabels = InterfaceScanner.declarations(
            matching: SymbolQuery("UIApplication.open(_:options:completionHandler:)"),
            in: sampleInterface,
            module: "UIKit",
            platform: .iOS
        )
        XCTAssertEqual(withLabels.count, 1)
        XCTAssertEqual(withLabels.first?.availability.introduced, "10.0")

        let wrongLabels = InterfaceScanner.declarations(
            matching: SymbolQuery("UIApplication.open(_:)"),
            in: sampleInterface,
            module: "UIKit",
            platform: .iOS
        )
        XCTAssertTrue(wrongLabels.isEmpty)
    }

    // MARK: - Module resolution

    func testDependencyDeploymentTargetIsABlockingIssue() {
        let output = """
            A.swift:9:8: error: compiling for iOS 15.0, but module 'PermissionCore' has a minimum deployment target of iOS 18.0: /build/PermissionCore.swiftmodule
            """

        let result = AvailabilityDiagnosticParser.parse(output, platform: .iOS)

        XCTAssertEqual(result.issues.map(\.kind), [.requiresNewer(version: "18.0")])
        XCTAssertEqual(result.issues.first?.symbol, "import PermissionCore")
        XCTAssertTrue(result.otherErrors.isEmpty)
    }

    func testMissingModuleIsNeverReportedAsPassing() {
        let report = AvailabilityReport(
            platform: .iOS,
            minimumVersion: "15.0",
            file: "A.swift",
            compiledFileCount: 1,
            issues: [],
            otherErrors: [],
            missingModules: ["PermissionCore"]
        )
        let matrix = AvailabilityMatrix(reports: [report])

        XCTAssertFalse(report.isComplete)
        XCTAssertFalse(report.summary.contains("✅"), report.summary)
        XCTAssertTrue(report.summary.contains("could not be fully checked"), report.summary)
        XCTAssertTrue(matrix.summary.contains("not checked"), matrix.summary)
        XCTAssertTrue(matrix.summary.contains("No checked version compiles"), matrix.summary)
    }

    func testCompilationUnitUsesWholeSwiftPMTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("APIAvailabilityTests-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("Sources/My-Target/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "// swift-tools-version: 5.9".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = target.appendingPathComponent("A.swift")
        try "struct A {}".write(to: file, atomically: true, encoding: .utf8)
        try "struct B {}".write(
            to: target.deletingLastPathComponent().appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)

        let unit = APIAvailabilityService.compilationUnit(containing: file)

        XCTAssertEqual(unit.moduleName, "My_Target")
        XCTAssertEqual(Set(unit.sources.map(\.lastPathComponent)), ["A.swift", "B.swift"])
        guard case .package(_, let targetName) = unit.origin else {
            return XCTFail("Expected a SwiftPM target, got \(unit.origin)")
        }
        XCTAssertEqual(targetName, "My-Target")
    }

    func testModuleDirectoriesFindsBuiltModules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("APIAvailabilityTests-\(UUID().uuidString)", isDirectory: true)
        let products = root.appendingPathComponent("out/Products/Debug-iphonesimulator", isDirectory: true)
        try FileManager.default.createDirectory(
            at: products.appendingPathComponent("Core.swiftmodule"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: products.appendingPathComponent("Other.swiftmodule"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            APIAvailabilityService.moduleDirectories(under: root).map(\.lastPathComponent),
            ["Debug-iphonesimulator"]
        )
    }

    // MARK: - Against the installed SDK

    func testCheckAgainstInstalledIOSSDK() async throws {
        try requireIOSSDK()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("APIAvailabilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("Screen.swift")
        try """
        import SwiftUI

        struct Screen: View {
            var body: some View {
                List {}
                    .scrollContentBackground(.hidden)
            }
        }

        struct Guarded: View {
            var body: some View {
                if #available(iOS 17.0, *) {
                    ContentUnavailableView("Empty", systemImage: "tray")
                } else {
                    Text("Empty")
                }
            }
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let service = APIAvailabilityService(
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("APIAvailabilityTests-cache"))
        let matrix = try await service.checkMatrix(
            filePath: file.path, versions: ["15", "16"], moduleFiles: [file.path])

        XCTAssertEqual(matrix.reports.map(\.minimumVersion), ["15.0", "16.0"])
        let ios15 = matrix.reports[0]
        XCTAssertEqual(ios15.blockingIssues.map(\.symbol), ["scrollContentBackground"], ios15.summary)
        XCTAssertEqual(ios15.blockingIssues.first?.line, 6)
        XCTAssertEqual(ios15.highestRequiredVersion, "16.0")
        XCTAssertTrue(ios15.otherErrors.isEmpty, ios15.summary)
        XCTAssertTrue(matrix.reports[1].blockingIssues.isEmpty, matrix.reports[1].summary)
    }

    func testLookupInInstalledSwiftUIInterface() async throws {
        try requireIOSSDK()

        let service = APIAvailabilityService(
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("APIAvailabilityTests-cache"))
        let declarations = try await service.lookup(symbol: "ContentUnavailableView", modules: ["SwiftUI"])

        XCTAssertFalse(declarations.isEmpty)
        XCTAssertTrue(declarations.allSatisfy { $0.availability.introduced == "17.0" })
    }

    private func requireIOSSDK() throws {
        #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["--sdk", "iphonesimulator", "--show-sdk-path"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try XCTSkipIf(process.terminationStatus != 0, "No iOS simulator SDK installed")
        #else
            throw XCTSkip("Apple SDKs are macOS-only")
        #endif
    }
}
