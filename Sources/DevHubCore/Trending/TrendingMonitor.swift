import Foundation

/// The Trending tab: the repositories on GitHub's trending page. It reads the public page, so it
/// needs no sign-in and no token; the tab never turns red and never sends a banner.
public struct TrendingMonitor: Monitor {
    public let id = "trending"
    public let title = "Trending"
    private let load: @Sendable () async throws -> Data

    public init(defaults: UserDefaults) {
        self.init()
    }

    init(load: @escaping @Sendable () async throws -> Data = { try await TrendingPage.load() }) {
        self.load = load
    }

    public func refresh() async throws -> MonitorSnapshot {
        let html = String(decoding: try await load(), as: UTF8.self)
        let repos = TrendingParser.parse(html)
        guard !repos.isEmpty else { throw TrendingError.noRepositories }
        let detail = TrendingDetail(repos: repos, fetchedAt: Date())
        return MonitorSnapshot(status: .clean, fetchedAt: detail.fetchedAt, summary: Self.summary(repos), scope: "trending", detail: detail)
    }

    /// `Trending: 25 repos · 1,526 stars today`
    public static func summary(_ repos: [TrendingRepo]) -> String {
        let today = repos.compactMap(\.starsToday).reduce(0, +)
        return today > 0
            ? "Trending: \(repos.count) repos · \(today.formatted()) stars today"
            : "Trending: \(repos.count) repos"
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

    public static func load() async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("DevHub/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TrendingError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else { throw TrendingError.badResponse(http.statusCode) }
        return data
    }
}
