import SwiftUI
import UIKit

// MARK: - Haptics

/// One place for the small taps, so every row and tile feels the same.
enum Haptic {
    /// Tapping a row or a transaction.
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

// MARK: - Zoom from the thing you tapped

// The tile (or row) you tap grows into the screen it opens, and shrinks back into the same spot when you
// swipe it away. Same motion as Photos and the App Store: the finger stays connected to what it touched.

extension View {
    /// Marks a tile or row as the place its screen zooms out of.
    /// No clip shape here on purpose: many tiles sit inside a card with no padding of their own, and clipping them
    /// trims the edges of letters, numbers and bars. Cards already draw their own rounded corners.
    @ViewBuilder func zoomSource(_ id: some Hashable, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: ns)
        } else {
            self
        }
    }

    /// Put on the sheet or pushed screen: it zooms out of the matching `zoomSource`.
    @ViewBuilder func zoomed(from id: some Hashable, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            self
        }
    }
}

private struct ZoomNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    /// The screen's zoom namespace, so its tiles can register as zoom sources.
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

// MARK: - Chart labels that never get cut off

/// Evenly spaced dates for a chart's bottom labels, kept away from both ends so the first and last label
/// always have room (a label sitting on the very edge of a chart gets cut in half).
func axisDates(_ dates: [Date], count: Int = 3) -> [Date] {
    guard let start = dates.min(), let end = dates.max(), end > start else { return dates.prefix(1).map { $0 } }
    let span = end.timeIntervalSince(start)
    return (0..<count).map { i in
        start.addingTimeInterval(span * (0.14 + 0.72 * Double(i) / Double(max(count - 1, 1))))
    }
}
