import Foundation

/// One platform entry of an `@available` attribute.
struct AvailabilityAttribute: Equatable, Sendable {
    /// "iOS", "macOS", ..., "*" for all platforms, or "swift".
    var platform: String
    var introduced: String?
    /// Deprecated without a version is recorded as "".
    var deprecated: String?
    var obsoleted: String?
    var isUnavailable = false
    var message: String?
    var renamed: String?

    /// Every `@available(...)` attribute in `text`, one entry per platform.
    static func parseAll(in text: String) -> [AvailabilityAttribute] {
        var attributes: [AvailabilityAttribute] = []
        var searchStart = text.startIndex

        while let marker = text.range(of: "@available(", range: searchStart..<text.endIndex) {
            guard let close = matchingParenthesis(in: text, openingAt: text.index(before: marker.upperBound)) else {
                break
            }
            let body = String(text[marker.upperBound..<close])
            attributes.append(contentsOf: parse(arguments: splitTopLevel(body)))
            searchStart = text.index(after: close)
        }

        return attributes
    }

    private static func parse(arguments: [String]) -> [AvailabilityAttribute] {
        guard let first = arguments.first else {
            return []
        }

        // Shorthand: @available(iOS 15.0, macOS 12.0, *)
        let firstParts = first.split(separator: " ")
        if firstParts.count == 2, firstParts[1].first?.isNumber == true {
            return arguments.compactMap { argument in
                let parts = argument.split(separator: " ")
                guard parts.count == 2 else { return nil }
                return AvailabilityAttribute(platform: String(parts[0]), introduced: String(parts[1]))
            }
        }

        // Long form: @available(iOS, introduced: 2.0, deprecated: 10.0, message: "...")
        var attribute = AvailabilityAttribute(platform: first)
        for argument in arguments.dropFirst() {
            let (label, value) = labeledArgument(argument)
            switch label {
            case "introduced": attribute.introduced = value
            case "deprecated": attribute.deprecated = value ?? ""
            case "obsoleted": attribute.obsoleted = value
            case "unavailable": attribute.isUnavailable = true
            case "message": attribute.message = value
            case "renamed": attribute.renamed = value
            default: break
            }
        }
        return [attribute]
    }

    private static func labeledArgument(_ argument: String) -> (String, String?) {
        guard let colon = argument.firstIndex(of: ":") else {
            return (argument, nil)
        }
        let label = argument[..<colon].trimmingCharacters(in: .whitespaces)
        var value = argument[argument.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return (label, value)
    }

    /// Split on commas that are not inside quotes or brackets.
    static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var previous: Character?

        for character in text {
            if character == "\"" && previous != "\\" {
                inString.toggle()
            } else if !inString {
                if "([<".contains(character) {
                    depth += 1
                } else if ")]>".contains(character) {
                    depth -= 1
                } else if character == "," && depth == 0 {
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    previous = character
                    continue
                }
            }
            current.append(character)
            previous = character
        }

        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty {
            parts.append(last)
        }
        return parts
    }

    /// Index of the `)` matching the `(` at `open`, skipping string literals.
    static func matchingParenthesis(in text: String, openingAt open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var previous: Character?
        var index = open

        while index < text.endIndex {
            let character = text[index]
            if character == "\"" && previous != "\\" {
                inString.toggle()
            } else if !inString {
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                }
            }
            previous = character
            index = text.index(after: index)
        }
        return nil
    }
}

/// Availability of a declaration on one platform, after inheriting from
/// enclosing types and extensions.
public struct ResolvedAvailability: Equatable, Sendable {
    public var introduced: String?
    public var deprecated: String?
    public var obsoleted: String?
    public var isUnavailable = false
    public var message: String?
    public var renamed: String?
    /// The enclosing declaration the introduced version came from, when not the declaration itself.
    public var inheritedFrom: String?

    /// Combine attribute layers, innermost (the declaration) first.
    static func resolve(
        layers: [(name: String?, attributes: [AvailabilityAttribute])],
        platform: ApplePlatform
    ) -> ResolvedAvailability {
        var resolved = ResolvedAvailability()

        for (index, layer) in layers.enumerated() {
            let relevant = layer.attributes.filter { $0.platform == platform.availabilityName || $0.platform == "*" }
            for attribute in relevant {
                if resolved.introduced == nil, let introduced = attribute.introduced {
                    resolved.introduced = introduced
                    if index > 0 {
                        resolved.inheritedFrom = layer.name
                    }
                }
                if resolved.deprecated == nil, let deprecated = attribute.deprecated {
                    resolved.deprecated = deprecated
                    resolved.message = resolved.message ?? attribute.message
                    resolved.renamed = resolved.renamed ?? attribute.renamed
                }
                if resolved.obsoleted == nil, let obsoleted = attribute.obsoleted {
                    resolved.obsoleted = obsoleted
                }
                if attribute.isUnavailable && !resolved.isUnavailable {
                    resolved.isUnavailable = true
                    resolved.message = resolved.message ?? attribute.message
                    resolved.renamed = resolved.renamed ?? attribute.renamed
                }
            }
        }

        return resolved
    }

    public func describe(platform: ApplePlatform) -> String {
        let name = platform.rawValue
        if isUnavailable {
            return "unavailable on \(name)" + detail
        }

        var parts: [String] = []
        if let introduced {
            let source = inheritedFrom.map { " (from \($0))" } ?? ""
            parts.append("\(name) \(introduced)+\(source)")
        } else {
            parts.append("no \(name) version restriction")
        }
        if let deprecated {
            if deprecated.isEmpty {
                parts.append("deprecated")
            } else if deprecated.hasPrefix("100000") {
                parts.append("will be deprecated (API_TO_BE_DEPRECATED)")
            } else {
                parts.append("deprecated in \(name) \(deprecated)")
            }
        }
        if let obsoleted {
            parts.append("removed in \(name) \(obsoleted)")
        }
        return parts.joined(separator: ", ") + (deprecated != nil || obsoleted != nil ? detail : "")
    }

    private var detail: String {
        var text = ""
        if let renamed, !renamed.isEmpty {
            text += " — use \(renamed)"
        }
        if let message, !message.isEmpty {
            text += " — \(message)"
        }
        return text
    }
}
