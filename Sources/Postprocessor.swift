import Foundation

struct CleanupRule {
    let section: String
    let name: String
    let description: String
}

enum Postprocessor {
    static let rules = [
        CleanupRule(section: "Style", name: "Lowercase + acronyms", description: "Lowercases everything, but keeps real acronyms (NASA, HTTP)."),
        CleanupRule(section: "Remove noise", name: "Strip fillers", description: "Removes uh / um and elongations (umbrella, uh-oh survive)."),
        CleanupRule(section: "Remove noise", name: "Strip sound-tags", description: "Removes *laughs*, *music* event tags."),
        CleanupRule(section: "Remove noise", name: "Delete lone marks", description: "Removes a stray space-bounded . or - (decimals, u.s., ellipses safe)."),
        CleanupRule(section: "Fix repetition", name: "Collapse word echo", description: "“ideas. ideas in there” → “ideas in there”."),
        CleanupRule(section: "Fix repetition", name: "Collapse restart-stutter", description: "“i like the. the plan” → “i like the plan”."),
        CleanupRule(section: "Finalize", name: "Whitespace squeeze", description: "Collapses extra spaces; removes space before punctuation."),
        CleanupRule(section: "Finalize", name: "Emptiness normalize", description: "If only noise remained, nothing is pasted."),
        CleanupRule(section: "Finalize", name: "Drop trailing period", description: "Removes the final sentence period for a casual feel (keeps ? ! and internal periods)."),
        CleanupRule(section: "Finalize", name: "Join at the cursor", description: "Pasting adds the separator: a chained dictation closes the previous one (“there. how”)."),
    ]

    private static let dedupStoplist: Set<String> = [
        "okay", "yeah", "that", "path", "testing", "exactly", "sure", "really",
        "thanks", "good", "hello", "wait", "stop", "done",
    ]
    private static let stutterWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "i", "i'm", "i've", "i'll",
    ]
    private static let filler = #"(?<![\w-])u[hm]+(?![\w-])"#

    static func process(_ text: String) -> String {
        process(text, dictionary: loadDictionary())
    }

    static func process(_ text: String, dictionary: [String: String]) -> String {
        var result = lexicalNormalize(text, dictionary: dictionary)
        result = replace(result, #"\*[^*\n]*\*"#, with: "")
        result = replace(result, #"(?:^|(?<=\s))[.\-](?=\s|$)"#, with: "")
        result = stripSpokenFillers(result)
        result = whitespaceSqueeze(result)
        result = collapseWordDuplication(result)
        result = collapseStutter(result)
        result = whitespaceSqueeze(result)
        result = emptinessNormalize(result)
        guard !result.isEmpty else { return "" }
        return replace(result, #"(?<=[a-z0-9])\.$"#, with: "")
    }

    private static func loadDictionary() -> [String: String] {
        guard let data = try? Data(contentsOf: Paths.dictionary),
              let dictionary = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dictionary
    }

    private static func lexicalNormalize(_ text: String, dictionary: [String: String]) -> String {
        let acronymRegex = regex(#"\b[A-Z]{2,}\b"#)
        let original = text as NSString
        let acronymMatches = acronymRegex.matches(
            in: text, range: NSRange(location: 0, length: original.length)
        )
        let result = NSMutableString(string: text.lowercased())
        for match in acronymMatches.reversed() {
            result.replaceCharacters(in: match.range, with: original.substring(with: match.range))
        }

        var normalized = result as String
        for key in dictionary.keys.sorted() where !key.hasPrefix("_") {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: key) + #"\b"#
            normalized = replace(normalized, pattern, with: dictionary[key]!, options: [.caseInsensitive])
        }
        return normalized
    }

    private static func stripSpokenFillers(_ input: String) -> String {
        var text = input
        while true {
            let previous = text
            text = replace(text, #"(?<=[.!?…])\s*"# + filler + #"\s*\.(?=\s|$)"#, with: "", options: [.caseInsensitive])
            text = replace(text, #",\s*"# + filler + #"\s*(?=,)"#, with: "", options: [.caseInsensitive])
            text = replace(text, #"(,\s*)"# + filler + #"\s+"#, with: "$1", options: [.caseInsensitive])
            text = replace(text, filler + #"\s*,\s*"#, with: "", options: [.caseInsensitive])
            text = replace(text, filler, with: "", options: [.caseInsensitive])
            text = replace(text, #",\s*(?=[.!?…])"#, with: "")
            if text == previous { return text }
        }
    }

    private static func collapseWordDuplication(_ input: String) -> String {
        let pattern = #"\b([a-z]{4,})\.\s+\1\b(?=([.,]?\s+[a-z]|[.,]?\s*$))"#
        var text = input
        while true {
            let previous = text
            text = replaceMatches(text, pattern: pattern) { match, source in
                let word = source.substring(with: match.range(at: 1))
                let follow = source.substring(with: match.range(at: 2))
                if dedupStoplist.contains(word) || follow.hasPrefix(",") {
                    return source.substring(with: match.range)
                }
                return word
            }
            if text == previous { return text }
        }
    }

    private static func collapseStutter(_ input: String) -> String {
        let pattern = #"\b([a-z][a-z'’]*)\s*[.?!,…]\s+(\1)\b"#
        var text = input
        while true {
            let previous = text
            text = replaceMatches(text, pattern: pattern, options: [.caseInsensitive]) { match, source in
                let word = source.substring(with: match.range(at: 1))
                return stutterWords.contains(word.lowercased())
                    ? word
                    : source.substring(with: match.range)
            }
            if text == previous { return text }
        }
    }

    private static func whitespaceSqueeze(_ text: String) -> String {
        replace(replace(text, #"[ \t]{2,}"#, with: " "), #"\s+([.,!?…])"#, with: "$1")
    }

    private static func emptinessNormalize(_ input: String) -> String {
        var text = replace(input, #"^[.,\-\s]+"#, with: "")
        text = replace(text, #"[\-,\s]+$"#, with: "")
        var stripped = replace(text, filler, with: "", options: [.caseInsensitive])
        stripped = replace(stripped, #"[.\-,*\s]"#, with: "")
        return stripped.isEmpty ? "" : text
    }

    private static func regex(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func replace(
        _ text: String,
        _ pattern: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        let source = text as NSString
        return regex(pattern, options: options).stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: source.length),
            withTemplate: replacement
        )
    }

    private static func replaceMatches(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        let source = text as NSString
        let matches = regex(pattern, options: options).matches(
            in: text, range: NSRange(location: 0, length: source.length)
        )
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            result.replaceCharacters(in: match.range, with: transform(match, source))
        }
        return result as String
    }
}
