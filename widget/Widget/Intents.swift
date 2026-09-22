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
    static let title: LocalizedStringResource = "ClaudeSwap"
    static let description = IntentDescription("Claude account usage at a glance.")

    @Parameter(title: "Appearance", default: .system)
    var appearance: AppearanceOption

    init() {}
}

/// ‹ / › on the widget. Runs in the extension process, which owns the page
/// state, then asks WidgetKit to redraw.
struct PageIntent: AppIntent {
    static let title: LocalizedStringResource = "Change ClaudeSwap widget page"
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

/// The auto-switch toggle. The widget cannot change cswap's settings itself:
/// it drops a request file for the backend to apply, then remembers what it
/// asked for so the toggle shows the new state until the snapshot agrees.
struct SetAutoswitchIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn ClaudeSwap auto-switch on or off"
    static let isDiscoverable = false

    @Parameter(title: "Enabled")
    var value: Bool

    init() {}

    init(enabled: Bool) {
        value = enabled
    }

    func perform() async throws -> some IntentResult {
        let now = Date()
        // A stale snapshot means no backend to apply the request: the chip is
        // drawn inert then, but a tap on an older rendering can still land.
        guard SnapshotFile.load().map({ !$0.isBackendStale(now: now) }) ?? false else {
            WidgetCenter.shared.reloadTimelines(ofKind: CswapWidget.kind)
            return .result()
        }
        let delivered = (try? AutoswitchRequest.write(enabled: value, at: now,
                                                      into: SnapshotFile.requestsDirectory)) != nil
        AutoswitchStore.set(PendingToggle(desired: value, requestedAt: now, delivered: delivered))
        if delivered {
            // The backend applies a request within about a second. Wait that
            // long for it, so the reload that follows usually draws the
            // confirmed state rather than the pending one.
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(250))
                if SnapshotFile.load()?.autoswitch?.enabled == value { break }
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: CswapWidget.kind)
        return .result()
    }
}

/// The last toggle request, in the extension's own sandboxed defaults. One
/// value, not per size: auto-switch is global, so every widget shows it alike.
enum AutoswitchStore {
    private static let key = "autoswitch.pending"

    static func pending() -> PendingToggle? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingToggle.self, from: data)
    }

    static func set(_ pending: PendingToggle) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// "Switch to this account". Like the toggle, it only asks: it drops a
/// switch request for the backend and remembers the target, so the detail
/// shows "Switching…" until the snapshot has it active.
struct SwitchAccountIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Claude account from the ClaudeSwap widget"
    static let isDiscoverable = false

    @Parameter(title: "Account")
    var number: Int

    init() {}

    init(number: Int) {
        self.number = number
    }

    func perform() async throws -> some IntentResult {
        let now = Date()
        // A stale snapshot means no backend to apply the request: the button
        // is not drawn then, but a tap on an older rendering can still land.
        let backendUp = SnapshotFile.load().map { !$0.isBackendStale(now: now) } ?? false
        let delivered = backendUp
            && (try? SwitchRequest.write(to: number, at: now, into: SnapshotFile.requestsDirectory)) != nil
        SwitchStore.set(PendingSwitch(target: number, requestedAt: now, delivered: delivered))
        if delivered {
            // Give the backend its ~1s to apply it, so the reload usually
            // draws the result rather than "Switching…".
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(250))
                if SnapshotFile.load()?.activeAccountNumber == number { break }
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: CswapWidget.kind)
        return .result()
    }
}

/// The last switch request, in the extension's own sandboxed defaults. One
/// value: the active account is global, so every widget shows it alike.
enum SwitchStore {
    private static let key = "switch.pending"

    static func pending() -> PendingSwitch? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingSwitch.self, from: data)
    }

    static func set(_ pending: PendingSwitch) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: key)
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
