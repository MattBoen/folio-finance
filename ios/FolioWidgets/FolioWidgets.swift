import SwiftUI
import WidgetKit

// The widgets themselves are drawn by ../FolioWidgetShared (shared with Folio Desktop). This file only says where Folio's data comes from.

struct FolioWidgetSource: WidgetDataSource {
    /// Folio's app leaves a summary in the shared app group after each refresh.
    static func current() -> WidgetSnapshot? { WidgetSnapshot.load() }
}

@main
struct FolioWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetWorthWidget<FolioWidgetSource>()
        SpendingWidget<FolioWidgetSource>()
        InvestmentsWidget<FolioWidgetSource>()
    }
}
