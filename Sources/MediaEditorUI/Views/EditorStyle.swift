import AppKit
import SwiftUI

/// Rondo's media-editor palette (original). System colours so light and dark both work.
enum EditorStyle {
    static let keep = Color(nsColor: .controlAccentColor)
    static let bleep = Color(nsColor: .systemPink)
    static let marker = Color(nsColor: .systemOrange)
    static let dim = Color.black.opacity(0.55)
    static let stage = Color.black
    static let trackBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    static let waveform = Color(nsColor: .secondaryLabelColor)
    static let playhead = Color.white

    static let handleWidth: CGFloat = 10
    static let cornerRadius: CGFloat = 8
}
