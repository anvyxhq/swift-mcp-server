import Foundation

/// A declaration found in an SDK module interface, with its availability.
public struct APIDeclaration: Equatable, Sendable {
    public let module: String
    /// The innermost enclosing type or extended type, if any.
    public let enclosingType: String?
    public let signature: String
    public let availability: ResolvedAvailability
}

/// A symbol query such as `ContentUnavailableView`, `UIApplication.open`
/// or `UIApplication.open(_:options:completionHandler:)`.
struct SymbolQuery: Equatable {
    let typeName: String?
    let name: String
    /// Argument labels when the query spells them out, e.g. ["_", "options"].
    let labels: [String]?

    init(_ text: String) {
        var base = text.trimmingCharacters(in: .whitespaces)
        var labels: [String]?

        if let open = base.firstIndex(of: "("), base.hasSuffix(")") {
            let inside = base[base.index(after: open)..<base.index(before: base.endIndex)]
            labels = inside.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
            base = String(base[..<open])
        }

        if let dot = base.lastIndex(of: ".") {
            typeName = String(base[..<dot])
            name = String(base[base.index(after: dot)...])
        } else {
            typeName = nil
            name = base
        }
        self.labels = labels
    }
}

/// Scans `.swiftinterface`-style text for declarations, tracking enclosing
/// types so members inherit their type's or extension's availability.
enum InterfaceScanner {
    private struct Context {
        let name: String?
        let attributes: [AvailabilityAttribute]
        /// Brace depth inside this declaration's body.
        let depth: Int
    }

    private static let typeKeywords: Set<String> = ["class", "struct", "enum", "protocol", "actor", "extension"]
    private static let declarationKeywords: Set<String> = typeKeywords.union([
        "typealias", "func", "var", "let", "case", "init", "subscript", "macro", "associatedtype",
    ])
    private static let modifiers: Set<String> = [
        "public", "open", "internal", "package", "private", "fileprivate", "final", "static", "override",
        "mutating", "nonmutating", "convenience", "required", "indirect", "dynamic", "lazy", "weak", "unowned",
        "nonisolated", "isolated", "consuming", "borrowing", "distributed", "optional", "prefix", "postfix",
        "infix", "__consuming",
    ]

    static func declarations(
        matching query: SymbolQuery,
        in text: String,
        module: String,
        platform: ApplePlatform
    ) -> [APIDeclaration] {
        var results: [APIDeclaration] = []
        var seenSignatures = Set<String>()
        var contexts: [Context] = []
        var pendingAttributes = ""
        var depth = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("#") {
                if line.hasPrefix("//") || line.isEmpty {
                    pendingAttributes = ""
                }
                continue
            }

            let (leadingAttributes, rest) = splitLeadingAttributes(line)
            if rest.isEmpty {
                pendingAttributes += " " + leadingAttributes
                continue
            }

            let attributeText = pendingAttributes + " " + leadingAttributes
            pendingAttributes = ""

            let declaration = parseDeclaration(rest)
            let delta = braceDelta(rest)

            if let declaration {
                let attributes = AvailabilityAttribute.parseAll(in: attributeText)

                if matches(declaration, query: query, enclosing: contexts.last(where: { $0.name != nil })?.name) {
                    let layers =
                        [(name: Optional(declaration.name), attributes: attributes)]
                        + contexts.reversed().map { (name: $0.name, attributes: $0.attributes) }
                    let enclosing = contexts.last(where: { $0.name != nil })?.name
                    let availability = ResolvedAvailability.resolve(layers: layers, platform: platform)
                    // Interfaces repeat declarations (`#if compiler` branches, the
                    // Swift overlay plus synthesized headers); one per shape is enough.
                    let key = [
                        enclosing.map { String(lastComponent($0)) } ?? "",
                        declaration.keyword,
                        declaration.name,
                        declaration.labels?.joined(separator: ":") ?? "",
                        availability.describe(platform: platform),
                    ].joined(separator: "|")
                    if seenSignatures.insert(key).inserted {
                        results.append(
                            APIDeclaration(
                                module: module,
                                enclosingType: enclosing,
                                signature: cleanSignature(rest),
                                availability: availability
                            )
                        )
                    }
                }

                if delta > 0 {
                    let isType = typeKeywords.contains(declaration.keyword)
                    contexts.append(
                        Context(
                            name: isType ? declaration.name : nil,
                            attributes: isType ? attributes : [],
                            depth: depth + 1
                        )
                    )
                }
            } else if delta > 0 {
                contexts.append(Context(name: nil, attributes: [], depth: depth + 1))
            }

            depth += delta
            while let last = contexts.last, last.depth > depth {
                contexts.removeLast()
            }
        }

        return results
    }

    // MARK: - Line parsing

    struct Declaration: Equatable {
        let keyword: String
        let name: String
        let labels: [String]?
    }

    static func parseDeclaration(_ text: String) -> Declaration? {
        var remainder = Substring(text)

        while true {
            remainder = remainder.drop(while: \.isWhitespace)
            let word = remainder.prefix(while: { $0.isLetter || $0 == "_" })
            guard !word.isEmpty else {
                return nil
            }

            let afterWord = remainder.dropFirst(word.count)
            let keyword = String(word)

            if keyword == "class", let next = nextWord(afterWord), declarationKeywords.contains(next), next != "class" {
                remainder = afterWord
                continue
            }
            if modifiers.contains(keyword) {
                // Access modifiers can carry a qualifier, e.g. `private(set)`.
                remainder = afterWord.hasPrefix("(") ? afterWord.drop(while: { $0 != ")" }).dropFirst() : afterWord
                continue
            }
            guard declarationKeywords.contains(keyword) else {
                return nil
            }

            if keyword == "init" || keyword == "subscript" {
                return Declaration(keyword: keyword, name: keyword, labels: argumentLabels(afterWord))
            }

            let nameStart = afterWord.drop(while: \.isWhitespace)
            var name = nameStart.prefix(while: { !" :<({=,".contains($0) && !$0.isWhitespace })
            if name.hasPrefix("`") {
                name = name.dropFirst().prefix(while: { $0 != "`" })
            }
            guard !name.isEmpty else {
                return nil
            }

            let labels = keyword == "func" ? argumentLabels(nameStart.dropFirst(name.count)) : nil
            return Declaration(keyword: keyword, name: String(name), labels: labels)
        }
    }

    private static func nextWord(_ text: Substring) -> String? {
        let word = text.drop(while: \.isWhitespace).prefix(while: { $0.isLetter || $0 == "_" })
        return word.isEmpty ? nil : String(word)
    }

    /// Argument labels of the first parameter list in `text` (after generics).
    private static func argumentLabels(_ text: Substring) -> [String]? {
        let string = String(text)
        guard let open = string.firstIndex(of: "("),
            let close = AvailabilityAttribute.matchingParenthesis(in: string, openingAt: open)
        else {
            return nil
        }
        let parameters = AvailabilityAttribute.splitTopLevel(String(string[string.index(after: open)..<close]))
        return parameters.compactMap { parameter in
            let head = parameter.split(separator: ":", maxSplits: 1).first ?? ""
            return head.split(separator: " ").first.map(String.init)
        }
    }

    private static func matches(_ declaration: Declaration, query: SymbolQuery, enclosing: String?) -> Bool {
        guard declaration.name == query.name else {
            return false
        }
        if let typeName = query.typeName {
            guard let enclosing, lastComponent(enclosing) == lastComponent(typeName) else {
                return false
            }
        }
        if let labels = query.labels {
            guard let declared = declaration.labels, declared == labels else {
                return false
            }
        }
        return true
    }

    private static func lastComponent(_ name: String) -> Substring {
        let base = name.prefix(while: { $0 != "<" })
        return base.split(separator: ".").last ?? base
    }

    /// Split leading `@attribute` / `@attribute(...)` tokens from a line.
    static func splitLeadingAttributes(_ line: String) -> (attributes: String, rest: String) {
        var index = line.startIndex

        while index < line.endIndex, line[index] == "@" {
            var end = line.index(after: index)
            while end < line.endIndex, line[end].isLetter || line[end].isNumber || line[end] == "_" || line[end] == "."
            {
                end = line.index(after: end)
            }
            if end < line.endIndex, line[end] == "(" {
                guard let close = AvailabilityAttribute.matchingParenthesis(in: line, openingAt: end) else {
                    return (line, "")
                }
                end = line.index(after: close)
            }
            index = end
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
        }

        return (String(line[..<index]), String(line[index...]))
    }

    /// Net `{` minus `}` outside string literals.
    private static func braceDelta(_ text: String) -> Int {
        var delta = 0
        var inString = false
        var previous: Character?
        for character in text {
            if character == "\"" && previous != "\\" {
                inString.toggle()
            } else if !inString {
                if character == "{" { delta += 1 }
                if character == "}" { delta -= 1 }
            }
            previous = character
        }
        return delta
    }

    private static func cleanSignature(_ text: String) -> String {
        var signature = text
        if signature.hasSuffix("{") {
            signature = String(signature.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return signature.count > 240 ? String(signature.prefix(240)) + "…" : signature
    }
}
