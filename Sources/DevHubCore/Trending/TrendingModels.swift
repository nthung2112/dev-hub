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
    /// Stars gained in the period the page covers.
    public let starsToday: Int?

    public init(owner: String, name: String, description: String? = nil, language: String? = nil,
                stars: Int? = nil, forks: Int? = nil, starsToday: Int? = nil) {
        self.owner = owner
        self.name = name
        self.description = description
        self.language = language
        self.stars = stars
        self.forks = forks
        self.starsToday = starsToday
    }

    public var id: String { "\(owner)/\(name)" }
    public var fullName: String { "\(owner)/\(name)" }
    public var url: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
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
