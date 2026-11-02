import Foundation

/// The result of type-checking a file against one deployment target.
public struct AvailabilityReport: Sendable {
    public let platform: ApplePlatform
    public let minimumVersion: String
    public let file: String
    /// Number of files compiled together with `file` so cross-file types resolve.
    public let compiledFileCount: Int
    public let issues: [AvailabilityIssue]
    public let otherErrors: [String]
    /// Imports that could not be resolved. The compiler stops at a missing
    /// module, so the rest of the file was not checked.
    public let missingModules: [String]
    public let notes: [String]

    public init(
        platform: ApplePlatform,
        minimumVersion: String,
        file: String,
        compiledFileCount: Int,
        issues: [AvailabilityIssue],
        otherErrors: [String],
        missingModules: [String],
        notes: [String] = []
    ) {
        self.platform = platform
        self.minimumVersion = minimumVersion
        self.file = file
        self.compiledFileCount = compiledFileCount
        self.issues = issues
        self.otherErrors = otherErrors
        self.missingModules = missingModules
        self.notes = notes
    }

    /// False when an import could not be resolved, so passing results cannot be trusted.
    public var isComplete: Bool { missingModules.isEmpty }

    /// Issues that stop the file from compiling at this deployment target.
    public var blockingIssues: [AvailabilityIssue] {
        issues.filter {
            switch $0.kind {
            case .deprecated: return false
            default: return true
            }
        }
    }

    public var deprecations: [AvailabilityIssue] {
        issues.filter {
            if case .deprecated = $0.kind { return true }
            return false
        }
    }

    /// The lowest deployment target at which none of the found APIs need a
    /// version check, or nil when nothing requires a newer OS.
    public var highestRequiredVersion: String? {
        issues.compactMap { issue -> String? in
            if case .requiresNewer(let version) = issue.kind { return version }
            return nil
        }.max(by: versionPrecedes)
    }

    public var summary: String {
        let target = "\(platform.rawValue) \(minimumVersion)"
        var lines: [String] = []

        if !isComplete {
            lines.append(
                "❓ \(file) could not be fully checked at \(target): module(s) \(missingModules.joined(separator: ", ")) not found, and the compiler stops at a missing import."
            )
            if notes.contains(where: { $0.hasPrefix("Dependencies failed") }) {
                lines.append(
                    "  Its dependencies do not build at \(target) (see below), so this target cannot support it either."
                )
            } else {
                lines.append(
                    "  Build the project once (Xcode or `swift build`) so its modules exist, or pass `module_files` to compile the needed sources together."
                )
            }
        }

        if blockingIssues.isEmpty {
            if isComplete {
                lines.append("✅ \(file) uses no API that is unavailable at \(target).")
            }
        } else {
            lines.append("❌ \(blockingIssues.count) API use(s) in \(file) are unavailable at \(target):")
            for issue in blockingIssues {
                lines.append("  \(issue.line):\(issue.column) \(describe(issue))")
            }
            if let required = highestRequiredVersion {
                lines.append(
                    "Fix: guard each use with `if #available(\(platform.rawValue) X, *)` (or `@available` on the enclosing declaration) and provide a fallback, or raise the deployment target to \(platform.rawValue) \(required)."
                )
            }
        }

        if !deprecations.isEmpty {
            lines.append("")
            lines.append("⚠️ \(deprecations.count) deprecated API use(s) at \(target):")
            for issue in deprecations {
                lines.append("  \(issue.line):\(issue.column) \(describe(issue))")
            }
        }

        if !otherErrors.isEmpty {
            lines.append("")
            lines.append(
                "Note: compiled \(compiledFileCount) file(s); code affected by these errors may hide further availability issues."
            )
            lines.append("  \(otherErrors.count) other compile error(s), e.g.:")
            for error in otherErrors.prefix(5) {
                lines.append("    \(error)")
            }
        }

        if !notes.isEmpty {
            lines.append("")
            lines.append(contentsOf: notes)
        }

        return lines.joined(separator: "\n")
    }

    private func describe(_ issue: AvailabilityIssue) -> String {
        let name = platform.rawValue
        switch issue.kind {
        case .requiresNewer(let version):
            return "'\(issue.symbol)' requires \(name) \(version)"
        case .deprecated(let version, let message):
            let since = version.map { " since \(name) \($0)" } ?? ""
            return "'\(issue.symbol)' deprecated\(since)" + (message.map { " — \($0)" } ?? "")
        case .obsoleted(let version):
            return "'\(issue.symbol)' removed in \(name) \(version)"
        case .unavailable(let message):
            return "'\(issue.symbol)' is unavailable on \(name)" + (message.map { " — \($0)" } ?? "")
        }
    }
}

/// Availability of one file across several deployment targets.
public struct AvailabilityMatrix: Sendable {
    public let reports: [AvailabilityReport]

    public var summary: String {
        guard let first = reports.first else {
            return "No versions checked."
        }

        let platform = first.platform.rawValue
        var lines = ["Availability of \(first.file) on \(platform):"]
        for report in reports {
            let blocking = report.blockingIssues
            if !report.isComplete && blocking.isEmpty {
                lines.append(
                    "  \(platform) \(report.minimumVersion): ❓ not checked — missing module(s) \(report.missingModules.joined(separator: ", "))"
                )
            } else if blocking.isEmpty {
                let deprecated = report.deprecations.isEmpty ? "" : " (\(report.deprecations.count) deprecated)"
                lines.append("  \(platform) \(report.minimumVersion): ✅ compiles\(deprecated)")
            } else {
                let symbols = Array(Set(blocking.map(\.symbol))).sorted().joined(separator: ", ")
                lines.append("  \(platform) \(report.minimumVersion): ❌ \(blocking.count) issue(s) — \(symbols)")
            }
        }

        if let lowest = reports.first(where: { $0.blockingIssues.isEmpty && $0.isComplete }) {
            lines.append("Lowest checked version that compiles without changes: \(platform) \(lowest.minimumVersion).")
        } else {
            lines.append("No checked version compiles without changes.")
        }

        if reports.contains(where: { !$0.isComplete || !$0.otherErrors.isEmpty || !$0.notes.isEmpty }) {
            lines.append(
                "Some versions have missing modules, build notes or other errors; run check_availability on one for details."
            )
        }

        return lines.joined(separator: "\n")
    }
}
