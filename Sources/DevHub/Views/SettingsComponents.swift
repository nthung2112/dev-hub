import AppKit
import SwiftUI
import DevHubCore

/// A tab's state as Settings shows it: a coloured dot, a short title and a line of detail.
enum TabHealth: Equatable {
    case loading
    case working(Date)
    case failed(String)
    case off

    var colour: Color {
        switch self {
        case .working: return .green
        case .failed: return .red
        case .loading, .off: return Color.secondary.opacity(0.5)
        }
    }

    var symbol: String {
        switch self {
        case .working: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .loading: return "clock"
        case .off: return "pause.circle"
        }
    }

    /// `Working · updated 10:12`, `Last refresh failed: …`, `Hidden, not refreshed`.
    var line: String {
        switch self {
        case .loading: return "Loading…"
        case .working(let date): return "Working · updated \(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let message): return "Last refresh failed: \(message)"
        case .off: return "Hidden, not refreshed"
        }
    }
}

extension TabState {
    var health: TabHealth {
        if case .error(let message)? = problem { return .failed(message) }
        if let lastRefreshed { return .working(lastRefreshed) }
        return .loading
    }
}

/// A titled, rounded box of rows, like a group in System Settings.
struct SettingsGroup<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            if let footer {
                Text(footer)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// The hairline between two rows of a `SettingsGroup`.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 10)
    }
}

/// A label (and optional explanation) on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var control: () -> Control

    init(_ label: String, help: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.help = help
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12))
                if let help {
                    Text(help)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

/// An on/off setting shown as a switch on the right.
struct SwitchRow: View {
    let label: String
    var help: String?
    @Binding var isOn: Bool
    var disabled = false

    init(_ label: String, help: String? = nil, isOn: Binding<Bool>, disabled: Bool = false) {
        self.label = label
        self.help = help
        _isOn = isOn
        self.disabled = disabled
    }

    var body: some View {
        SettingsRow(label, help: help) {
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
    }
}

/// Copies `text`, then reads "Copied" for a moment.
struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
        .help("Copy to the clipboard")
    }
}
