# Swift MCP Server

A [Model Context Protocol](https://modelcontextprotocol.io) server that gives AI agents and editors **semantic** access to Swift code. It exposes SourceKit-LSP — Apple's official language server — over `stdio` or HTTP, so a client can navigate, inspect, refactor, and diagnose Swift using the compiler's own understanding instead of text heuristics.

## Overview

AI coding agents read a codebase the way a search box does: as text. For prose that is fine, but source code is a graph of declarations, references, types, and conformances that text cannot see. An agent working from `grep` cannot reliably tell one `save()` from another overload, distinguish a shadowed local from the property it hides, know which types conform to a protocol, or find every real use of a symbol across files.

### The problem

When an agent guesses structure from text, the mistakes are quiet but expensive:

- **Broken refactors** — a find-and-replace rename misses call sites in other files, or rewrites matching text inside comments and strings.
- **Wrong navigation** — "go to the definition" lands on a same-named symbol in an unrelated file.
- **Missed relationships** — the agent cannot answer "who calls this?" or "what implements this protocol?" without reading the whole project and still guessing.

### What this solves

The server routes each request to SourceKit-LSP and returns the **compiler's** answer, not a text match:

- **Safe, workspace-wide renames** that update every real reference and nothing else.
- **Precise navigation** — exact definitions, implementations, and references resolved by the type checker.
- **Structural understanding** — call and type hierarchies, so an agent grasps how a large codebase fits together without reading every file.
- **Compiler diagnostics and fix-its** — read the actual errors, then apply the compiler's suggested fix.
- **Correct code for every OS version you support** — check a file against iOS 13, 15, 17, 26… with the real SDK, and look up when any Apple API appeared or was deprecated, so `if #available` branches are right before you ship.

In short, it turns "guessing from text" into "querying the compiler."

The server is deliberately small: it wraps only the operations that genuinely require a language server. Anything an LLM already does well from source text — summaries, explanations, code generation — is intentionally left to the client, which keeps every tool grounded in real compiler semantics.

## Requirements

- macOS with the Xcode toolchain
- Swift 5.9 or later to build
- `sourcekit-lsp` available through Xcode or on `PATH` (bundled with the toolchain)

Every tool depends on SourceKit-LSP. The core navigation tools work with any recent toolchain; the index-backed tools (`search_workspace_symbols`, `rename_symbol`, `call_hierarchy`, `type_hierarchy`, `get_implementations`) and `code_actions` fix-its are best with a current toolchain (Xcode 16 / Swift 6 or later), which ships the background indexing they rely on.

## Installation

```bash
swift build --configuration release
```

The binary is produced at `.build/release/swift-mcp-server`.

## Usage

Run over STDIO (for editors and AI clients):

```bash
.build/release/swift-mcp-server --transport stdio --workspace /path/to/project
```

Run over HTTP (for local API use and testing):

```bash
.build/release/swift-mcp-server --transport http --workspace /path/to/project --port 8080
```

The workspace may be passed with `--workspace <path>` or as a positional argument. A helper script is also provided:

```bash
./swift-mcp.sh build
./swift-mcp.sh health
./swift-mcp.sh stdio
```

### Client configuration

Point any MCP client that speaks `stdio` at the built binary:

```json
{
  "mcp": {
    "servers": {
      "swift-mcp-server": {
        "command": "/path/to/swift-mcp-server/.build/release/swift-mcp-server",
        "args": ["--transport", "stdio", "--workspace", "/path/to/project"]
      }
    }
  }
}
```

This works with any local MCP client, including Claude Code / Claude Desktop and Cursor / VS Code style setups. A ready-to-use example lives in [`vscode-mcp-config.json`](vscode-mcp-config.json).

## Tools

The navigation, inspection, structure and editing tools are backed by SourceKit-LSP; the availability tools use the compiler and SDKs of the active Xcode. Line and character arguments are **0-based**.

**Navigation & search**

| Tool | Purpose | Arguments |
| --- | --- | --- |
| `find_symbols` | List symbols declared in a file, filtered by name | `file_path`, `name_pattern` |
| `search_workspace_symbols` | Find symbols by name across the whole workspace | `query` |
| `find_references` | Find every reference to the symbol at a position | `file_path`, `line`, `character` |
| `get_definition` | Resolve the definition of the symbol at a position | `file_path`, `line`, `character` |
| `get_implementations` | Find concrete implementations of a protocol requirement or method | `file_path`, `line`, `character` |

**Inspection**

| Tool | Purpose | Arguments |
| --- | --- | --- |
| `get_hover_info` | Type and documentation for the symbol at a position | `file_path`, `line`, `character` |
| `get_diagnostics` | Compiler errors and warnings for a file | `file_path` |

**Structure**

| Tool | Purpose | Arguments |
| --- | --- | --- |
| `call_hierarchy` | Callers (`incoming`) or callees (`outgoing`) of a function | `file_path`, `line`, `character`, `direction` |
| `type_hierarchy` | `supertypes` or `subtypes`/conformers of a type | `file_path`, `line`, `character`, `direction` |

**Editing** (writes to disk)

| Tool | Purpose | Arguments |
| --- | --- | --- |
| `format_document` | Format a file and return the resulting edits | `file_path` |
| `rename_symbol` | Rename a symbol across the workspace and apply the edits | `file_path`, `line`, `character`, `new_name` |
| `code_actions` | List compiler fix-its / refactorings on a line, or `apply` one by title | `file_path`, `line`, `apply` |

**OS version availability**

| Tool | Purpose | Arguments |
| --- | --- | --- |
| `check_availability` | Type-check a file at a minimum OS version and list every API that needs a newer OS (with the version it needs) plus deprecated APIs | `file_path`, `minimum_version`, `platform`, `module_files` |
| `check_availability_matrix` | Same check at several versions at once, e.g. `["13", "15", "17", "26"]`, reporting the lowest that compiles | `file_path`, `versions`, `platform`, `module_files` |
| `api_availability` | When an SDK API was introduced, deprecated or removed — SwiftUI, UIKit, Foundation, SwiftData and more, including Objective-C frameworks | `symbol` (`Type`, `Type.member`, `Type.method(label:)`), `modules`, `platform` |

`platform` is `iOS` (default), `macOS`, `tvOS`, `watchOS` or `visionOS`.

Example `check_availability_matrix` result:

```text
Availability of Screen.swift on iOS:
  iOS 13.0: ❌ 5 issue(s) — ContentUnavailableView, Observable(), scrollContentBackground, sheetPresentationController, …
  iOS 15.0: ❌ 4 issue(s) — ContentUnavailableView, Observable(), scrollContentBackground, …
  iOS 16.0: ❌ 3 issue(s) — ContentUnavailableView, Observable(), …
  iOS 17.0: ✅ compiles (1 deprecated)
Lowest checked version that compiles without changes: iOS 17.0.
```

How the availability tools work:

- The file is compiled together with the rest of its SwiftPM target, or the app folder of its Xcode project, so types from other files resolve. Code inside `if #available` is understood, so correctly guarded code passes.
- For a SwiftPM package, the target's dependencies are built for the checked platform and version first (cached under `~/Library/Caches/swift-mcp-server`), so `import` works. If a dependency itself does not build at that version, the report says which API in it needs a newer OS.
- For an Xcode project, modules come from Xcode's last build in DerivedData. Build the app once if a module is reported missing.
- If an import still cannot be resolved, the result is marked **not checked** rather than passing, because the compiler stops at a missing module.
- `api_availability` reads the SDK's module interfaces, generating the Swift view of Objective-C frameworks with `swift-synthesize-interface` (Xcode 26 or later). The first lookup per SDK takes a few seconds; later lookups come from a cache.

The server also implements `initialize`, `tools/list`, `tools/call`, `resources/list`, and `resources/read`, and exposes a `swift://workspace` resource describing the active workspace.

> The index-backed tools rely on SourceKit-LSP's global index. Right after startup the index may still be building, so these tools wait a bounded amount of time for it to become ready before returning. The server also warms the index up in the background when it starts, so the first call is not penalized. `rename_symbol` and an applied `code_actions` modify files on disk.

## Languages

Every tool works on Swift, including SwiftUI (SwiftUI code is ordinary Swift).

Objective-C, C, and C++ are also supported. The server selects the LSP `languageId` from the file extension (`.m` → objective-c, `.mm` → objective-cpp, `.h` → objective-c, `.c` → c, `.cpp`/`.cc`/… → cpp), so SourceKit-LSP routes those files to `clangd`. C-family files additionally require a `compile_commands.json` in the workspace so `clangd` can resolve compiler arguments — pure SwiftPM packages do not emit one, so generate it from your build (e.g. an Xcode or CMake export) for mixed Swift/Objective-C projects.

## How it works

The server keeps a single SourceKit-LSP session bound to the workspace and translates each MCP tool call into the matching LSP request:

| Tool | LSP request |
| --- | --- |
| `find_symbols` | `textDocument/documentSymbol` (filtered by name) |
| `search_workspace_symbols` | `workspace/symbol` |
| `find_references` | `textDocument/references` |
| `get_definition` | `textDocument/definition` |
| `get_implementations` | `textDocument/implementation` |
| `get_hover_info` | `textDocument/hover` |
| `get_diagnostics` | `textDocument/publishDiagnostics` |
| `call_hierarchy` | `textDocument/prepareCallHierarchy` + `callHierarchy/incomingCalls` \| `outgoingCalls` |
| `type_hierarchy` | `textDocument/prepareTypeHierarchy` + `typeHierarchy/supertypes` \| `subtypes` |
| `format_document` | `textDocument/formatting` |
| `rename_symbol` | `textDocument/rename` (edits applied to disk) |
| `code_actions` | `textDocument/codeAction` (an applied action writes its edits to disk) |
| `check_availability`, `check_availability_matrix` | `swiftc -typecheck` with the platform's SDK and deployment target (not LSP) |
| `api_availability` | The SDK's `.swiftinterface` files and `swift-synthesize-interface` (not LSP) |

Because results come from the compiler's own index, they reflect real language semantics rather than text matching.

## Architecture

```text
Sources/
├── SwiftMCPServer/      CLI entry point and transport bootstrapping
├── SwiftMCPCore/        MCP protocol, transports, and configuration
├── SourceKitLSP/        standalone SourceKit-LSP client and language types
└── APIAvailability/     OS-version availability checks and SDK API lookup

Tests/
└── SwiftMCPServerTests/ protocol and SourceKit-LSP integration tests
```

`SourceKitLSP` is a self-contained library (depending only on Foundation and swift-log) that exposes `SwiftLanguageServer` and the LSP value types. It has no knowledge of MCP, so it can be depended on on its own as a reusable SourceKit-LSP client. `SwiftMCPCore` layers the MCP protocol and transports on top of it — the dependency is strictly one-directional.

## Development

```bash
swift test
```

Tests cover the JSON-RPC / MCP request and response shapes, the exposed tool surface, and the SourceKit-LSP-backed operations end-to-end. Tests that require SourceKit-LSP skip automatically when it is unavailable.

## Notes

- Logs are written to `stderr` so STDIO MCP output stays clean.
- HTTP mode supports automatic port selection via `--port-min` / `--port-max`.
- Set `SOURCEKIT_LSP_PATH` to use a specific `sourcekit-lsp` binary (e.g. a custom toolchain); otherwise common install locations are probed.

## License

See [LICENSE](LICENSE).
