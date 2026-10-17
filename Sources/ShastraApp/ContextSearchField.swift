import AppKit
import SwiftUI

/// NSPopover can present after SwiftUI's initial focus pass. Set its native initial responder.
struct ContextSearchField: NSViewRepresentable {
    @Binding var text: String
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var value: Binding<String>
        init(_ value: Binding<String>) { self.value = value }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            value.wrappedValue = field.stringValue
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($text) }
    func makeNSView(context: Context) -> NSTextField {
        let field = ContextQueryTextField()
        field.placeholderString = "Search files, projects, chats or skills…"
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search context")
        field.setAccessibilityIdentifier("context-search")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.value = $text
        if field.stringValue != text { field.stringValue = text }
    }
}

private final class ContextQueryTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.initialFirstResponder = self
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            window.makeKey()
            window.makeFirstResponder(self)
        }
    }
}
