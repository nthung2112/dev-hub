import AppKit
import SwiftUI
import DevHubCore

/// The Trending tab: the repositories on GitHub's trending page, newest first.
struct TrendingView: View {
    @ObservedObject var tab: TabState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if case .error(let message)? = tab.problem {
                ErrorText(message)
            }
            content
        }
        .onAppear { tab.store.refresh(tab: tab) }
    }

    private var toolbar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("GitHub trending").font(.system(size: 13, weight: .semibold))
            Text("github.com/trending").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if let detail = tab.detail(TrendingDetail.self) {
                Text("\(detail.repos.count) repos")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder private var content: some View {
        if let detail = tab.detail(TrendingDetail.self) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(detail.repos.enumerated()), id: \.element.id) { index, repo in
                    if index > 0 { RowDivider() }
                    TrendingRow(repo: repo, rank: index + 1) { tab.store.open(repo.url) }
                }
            }
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        } else if tab.problem == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the trending page…").foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }
}

/// One repository: its name, what it is, and how many stars it has.
private struct TrendingRow: View {
    let repo: TrendingRepo
    let rank: Int
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(repo.fullName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let description = repo.description {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    if let language = repo.language {
                        Label(language, systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(LabelIconStyle())
                            .help("Language: \(language)")
                    }
                    if let stars = repo.stars {
                        Label(stars.formatted(), systemImage: "star")
                            .font(.caption2).foregroundStyle(.secondary)
                            .labelStyle(LabelIconStyle())
                            .help("Total stars")
                    }
                    if let forks = repo.forks {
                        Label(forks.formatted(), systemImage: "tuningfork")
                            .font(.caption2).foregroundStyle(.secondary)
                            .labelStyle(LabelIconStyle())
                            .help("Forks")
                    }
                    if let today = repo.starsToday {
                        Label("\(today.formatted()) today", systemImage: "arrow.up.right")
                            .font(.caption2).foregroundStyle(.green)
                            .labelStyle(LabelIconStyle())
                            .help("Stars today")
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(hovering ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help("Open \(repo.fullName) on GitHub")
    }
}

/// An icon the size of the text, in a row.
private struct LabelIconStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}
