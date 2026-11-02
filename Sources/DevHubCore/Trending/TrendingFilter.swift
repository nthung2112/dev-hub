import Foundation

/// The languages the Trending tab can filter by, plus everything GitHub lists.
public enum TrendingLanguage: String, Sendable, CaseIterable, Identifiable {
    case all
    case typescript
    case javascript
    case python
    case java
    case go
    case rust

    public var id: String { rawValue }

    /// The name on the button.
    public var title: String {
        switch self {
        case .all: return "All languages"
        case .typescript: return "TypeScript"
        case .javascript: return "JavaScript"
        case .python: return "Python"
        case .java: return "Java"
        case .go: return "Go"
        case .rust: return "Rust"
        }
    }

    /// The path GitHub uses for the language; nil for every language.
    public var slug: String? {
        self == .all ? nil : rawValue
    }
}

/// The period GitHub ranks the repositories over.
public enum TrendingSince: String, Sendable, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    /// How the page words the stars gained over the period.
    public var periodPhrase: String {
        switch self {
        case .daily: return "today"
        case .weekly: return "this week"
        case .monthly: return "this month"
        }
    }
}

/// Which repositories the Trending tab shows.
public struct TrendingFilter: Sendable, Equatable {
    public var language: TrendingLanguage
    public var since: TrendingSince

    public init(language: TrendingLanguage = .all, since: TrendingSince = .daily) {
        self.language = language
        self.since = since
    }

    /// `https://github.com/trending/typescript?since=weekly`, or the page without a language.
    public var url: URL {
        var components = URLComponents(url: TrendingPage.url, resolvingAgainstBaseURL: false)!
        if let slug = language.slug {
            components.path = "/trending/\(slug)"
        }
        components.queryItems = [URLQueryItem(name: "since", value: since.rawValue)]
        return components.url!
    }
}

/// The Trending tab's own settings, kept under `trending.*` in the app's defaults.
public enum TrendingSettings {
    public static let languageKey = "trending.language"
    public static let sinceKey = "trending.since"

    /// The saved filter, or every language over the last day.
    public static func filter(defaults: UserDefaults) -> TrendingFilter {
        let language = defaults.string(forKey: languageKey).flatMap(TrendingLanguage.init(rawValue:)) ?? .all
        let since = defaults.string(forKey: sinceKey).flatMap(TrendingSince.init(rawValue:)) ?? .daily
        return TrendingFilter(language: language, since: since)
    }

    /// Saves the filter and returns it.
    public static func save(_ filter: TrendingFilter, defaults: UserDefaults) -> TrendingFilter {
        defaults.set(filter.language.rawValue, forKey: languageKey)
        defaults.set(filter.since.rawValue, forKey: sinceKey)
        return filter
    }
}
