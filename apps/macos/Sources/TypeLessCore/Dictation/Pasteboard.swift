import Foundation

/// Schreibt Text in die Zwischenablage.
///
/// Als Protokoll, damit der Koordinator ohne AppKit testbar bleibt — die Umsetzung mit
/// ``NSPasteboard`` liegt in der App-Schicht (`Sources/TypeLess/`).
public protocol Pasteboard: Sendable {
    func write(_ text: String)
}
