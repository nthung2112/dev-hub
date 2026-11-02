import Foundation
import Testing
@testable import DevHubCore

@Suite struct TrendingTests {
    /// A cut-down copy of the page's own markup: one repository with everything, one with only a name.
    static let html = """
    <article class="Box-row">
      <h2 class="h3 lh-condensed">
        <a href="/octo/example" class="Link">
      <span class="text-normal">octo /</span>
      example</a>
      </h2>
      <p class="col-9 color-fg-muted my-1 pr-4">
        An example &amp; its description
      </p>
      <div class="f6 color-fg-muted mt-2">
        <span class="d-inline-block">
          <span itemprop="programmingLanguage">Swift</span>
        </span>
        <a href="/octo/example/stargazers" class="Link--muted"><svg aria-label="star"></svg> 12,345</a>
        <a href="/octo/example/forks" class="Link--muted"><svg aria-label="fork"></svg> 678</a>
        <span class="d-inline-block float-sm-right">
          <svg aria-label="star"></svg>
          90 stars today
        </span>
      </div>
    </article>
    <article class="Box-row">
      <h2 class="h3 lh-condensed">
        <a href="/solo" class="Link">solo</a>
      </h2>
    </article>
    """

    @Test func readsTheRepositoriesOffThePage() {
        let repos = TrendingParser.parse(Self.html)
        #expect(repos.count == 1)
        let repo = repos[0]
        #expect(repo.fullName == "octo/example")
        #expect(repo.description == "An example & its description")
        #expect(repo.language == "Swift")
        #expect(repo.stars == 12345)
        #expect(repo.forks == 678)
        #expect(repo.starsInPeriod == 90)
    }

    @Test func readsTheStarsGainedOverThePeriod() {
        for phrase in ["today", "this week", "this month"] {
            let html = Self.html.replacingOccurrences(of: "90 stars today", with: "90 stars \(phrase)")
            #expect(TrendingParser.parse(html).first?.starsInPeriod == 90)
        }
    }

    @Test func skipsBlocksWithoutARepositoryName() {
        #expect(TrendingParser.parse(Self.html).map(\.fullName) == ["octo/example"])
        #expect(TrendingParser.parse("<article class=\"Box-row\"></article>").isEmpty)
        #expect(TrendingParser.parse("<p>no rows here</p>").isEmpty)
    }

    @Test func theMonitorReadsThePageAndNeverFails() async throws {
        let monitor = TrendingMonitor(filter: TrendingFilter(), load: { _ in Data(Self.html.utf8) })
        let snapshot = try await monitor.refresh()
        #expect(snapshot.status == .clean)
        #expect(snapshot.summary == "Trending: 1 repo · 90 stars today")
        let detail = snapshot.detail as? TrendingDetail
        #expect(detail?.repos.count == 1)
    }

    @Test func anEmptyPageIsAnError() async {
        let monitor = TrendingMonitor(filter: TrendingFilter(), load: { _ in Data("<html></html>".utf8) })
        await #expect(throws: TrendingError.self) { try await monitor.refresh() }
    }

    @Test func theFilterBuildsThePageUrl() {
        #expect(TrendingFilter(language: .typescript, since: .weekly).url.absoluteString
                == "https://github.com/trending/typescript?since=weekly")
        #expect(TrendingFilter(language: .all, since: .monthly).url.absoluteString
                == "https://github.com/trending?since=monthly")
        #expect(TrendingFilter(language: .rust, since: .daily).url.absoluteString
                == "https://github.com/trending/rust?since=daily")
    }

    @Test func theFilterIsSavedAndReadBack() {
        let defaults = UserDefaults(suiteName: "local.devhub.tests.trending")!
        defaults.removePersistentDomain(forName: "local.devhub.tests.trending")
        #expect(TrendingSettings.filter(defaults: defaults) == TrendingFilter(language: .all, since: .daily))
        TrendingSettings.save(TrendingFilter(language: .go, since: .monthly), defaults: defaults)
        #expect(TrendingSettings.filter(defaults: defaults) == TrendingFilter(language: .go, since: .monthly))
        defaults.removePersistentDomain(forName: "local.devhub.tests.trending")
    }

    @Test func theSummaryNamesTheLanguageAndPeriod() {
        let repos = [TrendingRepo(owner: "octo", name: "example", starsInPeriod: 90)]
        #expect(TrendingMonitor.summary(repos, filter: TrendingFilter(language: .all, since: .daily))
                == "Trending: 1 repo · 90 stars today")
        #expect(TrendingMonitor.summary(repos, filter: TrendingFilter(language: .typescript, since: .weekly))
                == "Trending TypeScript: 1 repo · 90 stars this week")
        #expect(TrendingMonitor.summary(repos, filter: TrendingFilter(language: .rust, since: .monthly))
                == "Trending Rust: 1 repo · 90 stars this month")
    }
}
