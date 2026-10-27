import SwiftUI

extension Color {
    static let folioSlate  = Color(red: 0.165, green: 0.188, blue: 0.251)  // #2A3040
    static let folioAmber  = Color(red: 0.831, green: 0.525, blue: 0.290)  // #D4864A
    static let folioCream  = Color(red: 0.969, green: 0.953, blue: 0.929)  // #F7F3ED
    static let folioSurface = Color(red: 0.980, green: 0.973, blue: 0.961) // slightly lighter cream
}

extension Font {
    static func folioSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}
