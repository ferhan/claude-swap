import AppIntents
import WidgetKit

/// Per-widget appearance, set from Edit Widget.
enum AppearanceOption: String, AppEnum {
    case system, light, dark

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Appearance"
    static let caseDisplayRepresentations: [AppearanceOption: DisplayRepresentation] = [
        .system: "System",
        .light: "Light",
        .dark: "Dark"
    ]
}

struct CswapConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "cswap"
    static let description = IntentDescription("Claude account usage at a glance.")

    @Parameter(title: "Appearance", default: .system)
    var appearance: AppearanceOption

    init() {}
}

/// ‹ / › on the widget. Runs in the extension process, which owns the page
/// state, then asks WidgetKit to redraw.
struct PageIntent: AppIntent {
    static let title: LocalizedStringResource = "Change cswap widget page"
    static let isDiscoverable = false

    @Parameter(title: "Family")
    var family: String

    @Parameter(title: "Step")
    var step: Int

    init() {}

    init(family: LayoutFamily, step: Int) {
        self.family = family.rawValue
        self.step = step
    }

    func perform() async throws -> some IntentResult {
        guard let layout = LayoutFamily(rawValue: family) else { return .result() }
        let count = SnapshotFile.load().map { Paging.pages(for: layout, snapshot: $0).count } ?? 1
        PageStore.step(layout, by: step, count: count)
        WidgetCenter.shared.reloadTimelines(ofKind: CswapWidget.kind)
        return .result()
    }
}

/// The current page, in the extension's own sandboxed defaults (no App Group).
///
/// Keyed by size, not by widget instance: WidgetKit gives neither the provider
/// nor an intent an identifier for the placed widget, so two widgets of the
/// same size page together.
enum PageStore {
    private static func key(_ family: LayoutFamily) -> String { "page.\(family.rawValue)" }

    static func index(_ family: LayoutFamily) -> Int {
        UserDefaults.standard.integer(forKey: key(family))
    }

    static func step(_ family: LayoutFamily, by step: Int, count: Int) {
        let next = Paging.normalized(index(family) + step, count: count)
        UserDefaults.standard.set(next, forKey: key(family))
    }
}

/// Tapping an account row: extra-large selects it in place; the list-based
/// sizes drill into its detail.
struct SelectAccountIntent: AppIntent {
    static let title: LocalizedStringResource = "Show account in ClaudeSwap widget"
    static let isDiscoverable = false

    @Parameter(title: "Family")
    var family: String

    @Parameter(title: "Account")
    var number: Int

    init() {}

    init(family: LayoutFamily, number: Int) {
        self.family = family.rawValue
        self.number = number
    }

    func perform() async throws -> some IntentResult {
        guard let layout = LayoutFamily(rawValue: family) else { return .result() }
        NavStore.set(Navigation.select(number, in: NavStore.state(layout), family: layout), for: layout)
        WidgetCenter.shared.reloadTimelines(ofKind: CswapWidget.kind)
        return .result()
    }
}

/// ▲ / ▼ beside an overflowing list: move it a window at a time, since a
/// widget cannot scroll.
struct ScrollListIntent: AppIntent {
    static let title: LocalizedStringResource = "Scroll ClaudeSwap widget list"
    static let isDiscoverable = false

    @Parameter(title: "Family")
    var family: String

    @Parameter(title: "Delta")
    var delta: Int

    init() {}

    init(family: LayoutFamily, delta: Int) {
        self.family = family.rawValue
        self.delta = delta
    }

    func perform() async throws -> some IntentResult {
        guard let layout = LayoutFamily(rawValue: family),
              let snapshot = SnapshotFile.load() else { return .result() }
        let chunks = Navigation.listChunks(for: layout, snapshot: snapshot)
        NavStore.set(Navigation.scroll(NavStore.state(layout), by: delta, chunks: chunks), for: layout)
        WidgetCenter.shared.reloadTimelines(ofKind: CswapWidget.kind)
        return .result()
    }
}

/// Behind everything that is not a control, so a stray tap reloads the widget
/// instead of launching the stub host app.
struct RefreshIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh ClaudeSwap widget"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: CswapWidget.kind)
        return .result()
    }
}

/// Navigation state, in the extension's own sandboxed defaults (no App Group),
/// keyed by size for the same reason as `PageStore`: WidgetKit gives no
/// identifier for a placed widget, so two widgets of one size share it.
enum NavStore {
    private static func key(_ family: LayoutFamily) -> String { "nav.\(family.rawValue)" }

    static func state(_ family: LayoutFamily) -> NavState {
        guard let data = UserDefaults.standard.data(forKey: key(family)),
              let state = try? JSONDecoder().decode(NavState.self, from: data) else { return NavState() }
        return state
    }

    static func set(_ state: NavState, for family: LayoutFamily) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key(family))
    }
}

extension LayoutFamily {
    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemLarge: self = .large
        case .systemExtraLarge: self = .extraLarge
        default: self = .medium
        }
    }
}
