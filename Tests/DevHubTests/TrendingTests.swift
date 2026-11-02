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
        #expect(repo.starsToday == 90)
    }

    @Test func skipsBlocksWithoutARepositoryName() {
        #expect(TrendingParser.parse(Self.html).map(\.fullName) == ["octo/example"])
        #expect(TrendingParser.parse("<article class=\"Box-row\"></article>").isEmpty)
        #expect(TrendingParser.parse("<p>no rows here</p>").isEmpty)
    }

    @Test func theMonitorReadsThePageAndNeverFails() async throws {
        let monitor = TrendingMonitor(load: { Data(Self.html.utf8) })
        let snapshot = try await monitor.refresh()
        #expect(snapshot.status == .clean)
        #expect(snapshot.summary == "Trending: 1 repos · 90 stars today")
        let detail = snapshot.detail as? TrendingDetail
        #expect(detail?.repos.count == 1)
    }

    @Test func anEmptyPageIsAnError() async {
        let monitor = TrendingMonitor(load: { Data("<html></html>".utf8) })
        await #expect(throws: TrendingError.self) { try await monitor.refresh() }
    }
}
