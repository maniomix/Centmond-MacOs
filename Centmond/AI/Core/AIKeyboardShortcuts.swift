import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleAIChat = Self("toggleAIChat", default: .init(.zero, modifiers: [.command, .shift]))
}
