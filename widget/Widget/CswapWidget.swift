import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    /// Raw stored page; normalized against the current page list at render.
    let pageIndex: Int
    /// Raw stored navigation; resolved against the snapshot at render.
    var nav = NavState()
    /// The last auto-switch toggle request; resolved against the snapshot at
    /// render.
    var pendingToggle: PendingToggle?
    let appearance: AppearanceOption
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: nil, pageIndex: 0, appearance: .system)
    }

    func snapshot(for configuration: CswapConfigIntent, in context: Context) async -> Entry {
        entry(configuration, context)
    }

    func timeline(for configuration: CswapConfigIntent, in context: Context) async -> Timeline<Entry> {
        // One entry (two while a toggle request is pending): every ticking thing on screen is a `Text(date:style:)`
        // driven by an absolute `resetsAt`, so WidgetKit ticks the countdowns
        // itself. The reload is what picks up a newer snapshot file (and
        // refreshes the human "3d 11h" countdowns).
        // 60s matches the backend's own poll interval: asking for less would
        // only re-read a file that cannot have changed. WidgetKit budgets
        // reloads and may serve them less often than requested -- this is the
        // ceiling, not a guarantee.
        // A toggle request still waiting on the backend changes the drawing
        // at its timeout, so that moment gets its own entry and a reload.
        let now = Date.now
        let first = entry(configuration, context, at: now)
        let reload = now.addingTimeInterval(60)
        guard let expiry = AutoswitchToggle.expiry(of: first.pendingToggle, now: now) else {
            return Timeline(entries: [first], policy: .after(reload))
        }
        let second = Entry(date: expiry, snapshot: first.snapshot, pageIndex: first.pageIndex, nav: first.nav,
                           pendingToggle: first.pendingToggle, appearance: first.appearance)
        return Timeline(entries: [first, second], policy: .after(min(reload, expiry.addingTimeInterval(1))))
    }

    private func entry(_ configuration: CswapConfigIntent, _ context: Context, at date: Date = .now) -> Entry {
        let family = LayoutFamily(context.family)
        return Entry(date: date,
                     snapshot: SnapshotFile.load(),
                     pageIndex: PageStore.index(family),
                     nav: NavStore.state(family),
                     pendingToggle: AutoswitchStore.pending(),
                     appearance: configuration.appearance)
    }
}

/// Applies the per-widget Appearance and the container background.
struct WidgetRoot: View {
    let entry: Entry
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let scheme: ColorScheme = switch entry.appearance {
        case .system: systemScheme
        case .light: .light
        case .dark: .dark
        }
        CswapWidgetView(entry: entry)
            .containerBackground(for: .widget) { background }
            .environment(\.colorScheme, scheme)
    }

    /// System: the window background, mostly opaque. A lighter fill let
    /// Liquid Glass wash the text out on a light desktop; this keeps a hint
    /// of the desktop behind it. Accented and vibrant rendering drop the
    /// container background, so those modes are unaffected.
    /// Forced modes: the glass still follows the system appearance, so they
    /// lay their own light/dark tint over it to keep the forced text legible.
    @ViewBuilder private var background: some View {
        switch entry.appearance {
        case .system: Rectangle().fill(.background.opacity(0.88))
        case .light: Color.white.opacity(0.88)
        case .dark: Color(white: 0.11).opacity(0.88)
        }
    }
}

struct CswapWidget: Widget {
    // Was "CswapWidget". chronod caches the descriptor per (extension bundle
    // id, kind) and kept serving the old display name; both had to change.
    nonisolated static let kind = "ClaudeSwapWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: CswapConfigIntent.self, provider: Provider()) { entry in
            WidgetRoot(entry: entry)
        }
        .configurationDisplayName("ClaudeSwap")
        .description("Claude account usage at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}
