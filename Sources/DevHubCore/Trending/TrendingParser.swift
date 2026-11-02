import Foundation

/// Reads GitHub's trending page. The page is HTML, so each repository is pulled out of its
/// `<article class="Box-row">` block with the few patterns the page uses.
public enum TrendingParser {
    public static func parse(_ html: String) -> [TrendingRepo] {
        blocks(in: html).compactMap { parseBlock($0) }
    }

    /// The repository blocks on the page, in the order they appear.
    static func blocks(in html: String) -> [String] {
        var found: [String] = []
        var rest = Substring(html)
        let marker = "<article class=\"Box-row\">"
        while let start = rest.range(of: marker) {
            let after = rest[start.upperBound...]
            let end = after.range(of: marker)?.lowerBound ?? after.endIndex
            found.append(String(after[..<end]))
            rest = after[end...]
        }
        return found
    }

    static func parseBlock(_ block: String) -> TrendingRepo? {
        guard let path = firstMatch(in: block, pattern: #"<h2[^>]*>.*?href="/([^"]+)""#),
              let (owner, name) = split(path) else { return nil }
        return TrendingRepo(
            owner: owner,
            name: name,
            description: text(in: block, pattern: #"<p class="col-9[^"]*"[^>]*>(.*?)</p>"#),
            language: text(in: block, pattern: #"<span itemprop="programmingLanguage"[^>]*>(.*?)</span>"#),
            stars: number(in: block, pattern: #"href="/[^"]+/stargazers"[^>]*>(.*?)</a>"#),
            forks: number(in: block, pattern: #"href="/[^"]+/forks"[^>]*>(.*?)</a>"#),
            starsInPeriod: number(in: block, pattern: #"([\d,]+)\s+stars\s+(today|this week|this month)"#)
        )
    }

    /// `owner/name`, as the page's link has it.
    private static func split(_ path: String) -> (String, String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// The first capture group, with the tags stripped out and the entities decoded.
    private static func text(in source: String, pattern: String) -> String? {
        guard let raw = firstMatch(in: source, pattern: pattern) else { return nil }
        let clean = decode(stripTags(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// The number in the first capture group, with the tags and thousands separators taken out.
    private static func number(in source: String, pattern: String) -> Int? {
        guard let raw = firstMatch(in: source, pattern: pattern) else { return nil }
        let digits = stripTags(raw).filter { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func firstMatch(in source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    private static func stripTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]*>", options: [.dotMatchesLineSeparators]) else { return html }
        return regex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: " ")
    }

    /// `&amp;` becomes `&`, `&#39;` becomes `'`.
    static func decode(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                    ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }
}
