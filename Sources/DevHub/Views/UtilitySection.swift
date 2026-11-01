import SwiftUI
import DevHubCore

/// Which Mac tab sections are folded away, remembered under `utilities.collapsed`.
@MainActor
final class UtilityLayout: ObservableObject {
    static let collapsedKey = "utilities.collapsed"
    static let sections = ["keepAwake", "pomodoro", "displays", "port", "finder", "screenshots", "power", "cleanup", "network"]

    private let defaults: UserDefaults
    @Published private(set) var collapsed: Set<String>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        collapsed = Set(defaults.stringArray(forKey: Self.collapsedKey) ?? [])
    }

    func isExpanded(_ id: String) -> Bool { !collapsed.contains(id) }

    func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        save()
    }

    var allCollapsed: Bool { Set(Self.sections).isSubset(of: collapsed) }

    func setAll(expanded: Bool) {
        collapsed = expanded ? [] : Set(Self.sections)
        save()
    }

    private func save() {
        defaults.set(collapsed.sorted(), forKey: Self.collapsedKey)
    }
}

/// A Mac tab section: a coloured header with an icon, a one-line description and a status chip,
/// which folds the rows below it away when clicked.
struct UtilitySection<Content: View, Status: View>: View {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    var footer: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var status: () -> Status
    @EnvironmentObject private var layout: UtilityLayout
    @State private var hovering = false

    init(_ id: String, title: String, subtitle: String, symbol: String, tint: Color, footer: String? = nil,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder status: @escaping () -> Status) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.footer = footer
        self.content = content
        self.status = status
    }

    private var expanded: Bool { layout.isExpanded(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .transition(.opacity)
                if let footer {
                    Text(footer)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.primary.opacity(0.025))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(expanded ? 0.28 : 0.14)))
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { layout.toggle(id) }
        } label: {
            HStack(spacing: 10) {
                IconBadge(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                status()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(tint.opacity(hovering ? 0.13 : 0.07))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(expanded ? "Click to fold away" : "Click to show")
        .accessibilityLabel("\(title), \(expanded ? "expanded" : "collapsed")")
    }
}

extension UtilitySection where Status == EmptyView {
    init(_ id: String, title: String, subtitle: String, symbol: String, tint: Color, footer: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(id, title: title, subtitle: subtitle, symbol: symbol, tint: tint, footer: footer, content: content) { EmptyView() }
    }
}

/// A white symbol on a rounded square of `tint`, like the icons in System Settings.
struct IconBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(
                LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .shadow(color: tint.opacity(0.3), radius: 1, y: 0.5)
    }
}

/// A figure with a bar under it, e.g. battery charge or disk used.
struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    /// 0-1, how full the bar is.
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 5)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A short state in a capsule, e.g. `On · until 14:30`.
struct StatusChip: View {
    let text: String
    var tint: Color = .secondary
    var symbol: String?

    init(_ text: String, tint: Color = .secondary, symbol: String? = nil) {
        self.text = text
        self.tint = tint
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(tint.opacity(0.14), in: Capsule())
        .frame(maxWidth: 190, alignment: .trailing)
    }
}
