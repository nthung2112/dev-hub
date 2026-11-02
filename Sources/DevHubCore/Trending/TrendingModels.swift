import Foundation

/// One repository on GitHub's trending page.
public struct TrendingRepo: Sendable, Codable, Equatable, Identifiable {
    public let owner: String
    public let name: String
    public let description: String?
    /// The language GitHub lists for the repository, if any.
    public let language: String?
    /// Total stars.
    public let stars: Int?
    /// Total forks.
    public let forks: Int?
    /// Stars gained over the period the page covers: today, this week or this month.
    public let starsInPeriod: Int?

    public init(owner: String, name: String, description: String? = nil, language: String? = nil,
                stars: Int? = nil, forks: Int? = nil, starsInPeriod: Int? = nil) {
        self.owner = owner
        self.name = name
        self.description = description
        self.language = language
        self.stars = stars
        self.forks = forks
        self.starsInPeriod = starsInPeriod
    }

    public var id: String { "\(owner)/\(name)" }
    public var fullName: String { "\(owner)/\(name)" }
    public var url: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
}

/// The counts as GitHub writes them: `109,278`, with a comma whatever the Mac's locale is.
public enum TrendingFormat {
    public static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// `1 repo`, `25 repos`.
    public static func repos(_ count: Int) -> String {
        count == 1 ? "1 repo" : "\(count) repos"
    }
}

/// What the Trending tab shows: the repositories on the page, in the order it lists them.
public struct TrendingDetail: MonitorDetail, Equatable {
    public let repos: [TrendingRepo]
    public let fetchedAt: Date

    public init(repos: [TrendingRepo], fetchedAt: Date) {
        self.repos = repos
        self.fetchedAt = fetchedAt
    }
}
