# Changelog

All notable changes to the Swift MCP Server project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

A ground-up overhaul that refocuses the server on SourceKit-LSP. This is a
breaking change from 1.x; tag it as `v2.0.0` when released.

### Added
- OS version availability tools, so code is correct for every OS version an app supports:
  - `check_availability` type-checks a file at a minimum OS version with the installed SDK and lists APIs that need a newer OS, deprecated APIs, and dependencies built for a newer OS.
  - `check_availability_matrix` runs that check for several versions at once and reports the lowest one that compiles.
  - `api_availability` looks up when an SDK API was introduced, deprecated or removed, including Objective-C frameworks such as UIKit.
  - New `APIAvailability` library target and product.
- Index-backed navigation tools: `search_workspace_symbols`, `get_implementations`, `call_hierarchy`, and `type_hierarchy`. They wait a bounded amount of time for SourceKit-LSP's global index to warm up before returning.
- Refactoring tools that write to disk: `rename_symbol` (workspace-wide) and `code_actions` (list compiler fix-its / refactorings on a line, or apply one by title). `code_actions` declares `codeActionLiteralSupport` and replays the original diagnostics so fix-its resolve.
- Objective-C / C / C++ support: the LSP `languageId` is chosen from the file extension (`.m`, `.mm`, `.h`, `.c`, `.cpp`, …) so SourceKit-LSP routes C-family files to `clangd`. (SwiftUI already worked, being ordinary Swift.)
- Background SourceKit-LSP warm-up when a transport starts, so the first tool call does not pay the full startup and index latency.

### Changed
- **Focused the tool surface on SourceKit-LSP.** The core set is `find_symbols`, `find_references`, `get_definition`, `get_hover_info`, `format_document`, and `get_diagnostics`, alongside the tools listed above — every tool is grounded in real compiler semantics.
- Extracted the SourceKit-LSP client into a standalone `SourceKitLSP` library target and product (`SwiftLanguageServer`, the LSP value types, and `JSONValue`), depending only on Foundation and swift-log. `SwiftMCPCore` layers the MCP protocol on top; the dependency is one-directional, so the client is reusable on its own.
- `SwiftLanguageServer` dropped its mutable `isInitialized` flag; startup is delegated to the SourceKit-LSP actor's idempotent guard, making the type safe to share across concurrent requests.

### Removed
- Heuristic project/architecture analysis, documentation and template generation, project-memory, iOS framework analysis, and the Apple SDK catalog — along with the `analyze_project`, `detect_architecture`, `analyze_symbol_usage`, `analyze_pop_usage`, `create_project_memory`, `generate_migration_plan`, `intelligent_project_memory`, `generate_documentation`, `analyze_ios_frameworks`, and `generate_template` tools. Their output was either trivially derivable by an LLM client or low-confidence heuristics.
- The `ModernConcurrency` module and library product (~2k lines): a task manager, thread-safe collections, and continuation helpers carried over from another project and unused by the MCP request path, which relies on Swift actors, structured concurrency, and SwiftNIO.
- The `swift-syntax` dependency and the `analysis` configuration block.

### Fixed
- **stdout ordering race:** SourceKit-LSP output was ingested via one detached `Task` per read callback, which the actor could run out of order and corrupt LSP message framing. Output now flows through a single ordered `AsyncStream` consumer.
- **Double-start race:** `start()` suspended on the initialize round-trip before marking the session started, so concurrent callers could spawn two SourceKit-LSP processes. Callers now coalesce onto a single start task.
- `rename_symbol` collapses aliased file URIs (e.g. `/tmp` vs `/private/tmp`) to a canonical path and dedupes edits, so a file is never rewritten twice.
- Honor `SOURCEKIT_LSP_PATH` to select a specific `sourcekit-lsp` binary (falling back to the common locations).

### Performance
- Applying rename/code-action edits precomputes line offsets once instead of rescanning the file per edit (was O(n²) in file size).

## [1.0.0]

Initial release: a Swift MCP server built on SourceKit-LSP, bundled with a
suite of heuristic project-analysis tools (architecture detection,
protocol-oriented-programming scoring, documentation/template generation,
project memory). Those analysis tools were removed in the overhaul above in
favor of a focused, compiler-backed tool set.
