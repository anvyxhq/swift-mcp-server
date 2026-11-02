import Foundation

struct ToolOutput: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ToolRunner {
    /// Run a command-line tool to completion off the cooperative thread pool,
    /// draining stdout and stderr concurrently so a chatty tool cannot block
    /// on a full pipe. The process is terminated after `timeout` seconds.
    static func run(
        _ executablePath: String,
        _ arguments: [String],
        timeout: TimeInterval = 300
    ) async throws -> ToolOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: APIAvailabilityError.toolFailed(executablePath, error.localizedDescription))
                    return
                }

                let watchdog = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                let stdoutBox = DataBox()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global().async {
                    stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.wait()
                process.waitUntilExit()
                watchdog.cancel()

                continuation.resume(
                    returning: ToolOutput(
                        status: process.terminationStatus,
                        stdout: String(decoding: stdoutBox.data, as: UTF8.self),
                        stderr: String(decoding: stderrData, as: UTF8.self)
                    )
                )
            }
        }
    }

    /// Run `xcrun` with the given arguments and return trimmed stdout, or nil on failure.
    static func xcrun(_ arguments: [String]) async -> String? {
        guard let output = try? await run("/usr/bin/xcrun", arguments), output.status == 0 else {
            return nil
        }
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
