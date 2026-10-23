import SwiftUI
import AppKit

enum OSwindTheme {
    static let accent = Color(nsColor:NSColor(name:NSColor.Name("OSwindAccent"),dynamicProvider: { appearance in
        if appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua { return NSColor(red:0.32,green:0.76,blue:0.65,alpha:1) }
        return NSColor(red:0.12,green:0.45,blue:0.35,alpha:1)
    }))
}
