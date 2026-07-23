import SwiftUI

extension View {
    /// `navigationBarTitleDisplayMode(.inline)` solo existe en iOS; no-op en macOS
    /// (el build de host usado por los tests).
    @ViewBuilder
    func navigationBarTitleDisplayModeInlineCompat() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `.insetGrouped` solo existe en iOS; en macOS (host de los tests) usa el estilo por defecto.
    @ViewBuilder
    func insetGroupedListStyleCompat() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self
        #endif
    }
}
