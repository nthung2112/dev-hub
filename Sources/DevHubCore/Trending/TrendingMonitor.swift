import Foundation

/// The Trending tab: the repositories on GitHub's trending page, for the saved language and
/// period. It reads the public page, so it needs no sign-in and no token; the tab never turns red
/// and never sends a banner.
public struct TrendingMonitor: Monitor {
    public let id = "trending"
    public let title = "Trending"
    private let filter: TrendingFilter
    private let load: @Sendable (URL) async throws -> Data

    public init(defaults: UserDefaults) {
        self.init(filter: TrendingSettings.filter(defaults: defaults))
    }

    init(filter: TrendingFilter = TrendingFilter(),
         load: @escaping @Sendable (URL) async throws -> Data = { try await TrendingPage.load(url: $0) }) {
        self.filter = filter
        self.load = load
    }

    public func refresh() async throws -> MonitorSnapshot {
        let html = String(decoding: try await load(filter.url), as: UTF8.self)
        let repos = TrendingParser.parse(html)
        guard !repos.isEmpty else { throw TrendingError.noRepositories }
        let detail = TrendingDetail(repos: repos, fetchedAt: Date())
        return MonitorSnapshot(status: .clean, fetchedAt: detail.fetchedAt, summary: Self.summary(repos, filter: filter),
                               scope: "trending:\(filter.language.rawValue):\(filter.since.rawValue)", detail: detail)
    }

    /// `Trending: 25 repos · 1,526 stars today`, `Trending TypeScript: 1 repo · 5,852 stars this week`
    public static func summary(_ repos: [TrendingRepo], filter: TrendingFilter) -> String {
        let total = repos.compactMap(\.starsInPeriod).reduce(0, +)
        let head = filter.language == .all ? "Trending" : "Trending \(filter.language.title)"
        let count = TrendingFormat.repos(repos.count)
        return total > 0
            ? "\(head): \(count) · \(TrendingFormat.count(total)) stars \(filter.since.periodPhrase)"
            : "\(head): \(count)"
    }
}

public enum TrendingError: LocalizedError {
    case badResponse(Int)
    case noRepositories

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "GitHub answered \(code)"
        case .noRepositories: return "No repositories on the trending page"
        }
    }
}

/// Fetches the trending page.
public enum TrendingPage {
    public static let url = URL(string: "https://github.com/trending")!

    public static func load(url: URL = TrendingPage.url) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("DevHub/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TrendingError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else { throw TrendingError.badResponse(http.statusCode) }
        return data
    }
}
