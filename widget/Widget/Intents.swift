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
