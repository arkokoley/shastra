import AppKit
import SwiftUI

/// AppKit's text system handles selection, scrolling and large files.
struct NativeTextPreview: NSViewRepresentable {
    let text: String
    let language: String

    final class Coordinator {
        var text: String?
        var language = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.backgroundColor = .textBackgroundColor
        view.textColor = .labelColor
        let scroll = PreviewScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, textView: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView,
              let layout = view.layoutManager, let container = view.textContainer else { return }
        guard context.coordinator.text != text || context.coordinator.language != language else { return }
        let textChanged = context.coordinator.text != text
        context.coordinator.text = text
        context.coordinator.language = language
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        // Simple visual highlighting; the preview does not interpret or execute code.
        let patterns: [(String, NSColor)] = [
            (#"\b(import|from|let|var|func|class|struct|enum|if|else|return|guard|for|while|def|async|await|const|function|export|public|private|static|try|catch|throw|true|false|nil|null|None|self)\b"#, .systemPurple),
            (#"\b\d+(\.\d+)?\b"#, .systemOrange),
            (#"\"([^\"\\]|\\.)*\"|'([^'\\]|\\.)*'"#, .systemGreen),
            (#"(?m)//[^\n]*|^[ \t]*#[^\n]*"#, .secondaryLabelColor)
        ]
        let supported = ["swift", "py", "js", "ts", "tsx", "jsx", "json", "go", "rs", "c", "h", "sh", "zsh"]
        if supported.contains(language.lowercased()), text.utf16.count <= 300_000 {
            let range = NSRange(location: 0, length: attributed.length)
            for (pattern, color) in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    for match in regex.matches(in: text, range: range) {
                        attributed.addAttribute(.foregroundColor, value: color, range: match.range)
                    }
                }
            }
        }
        view.textStorage?.setAttributedString(attributed)
        if textChanged {
            // NSTextView starts with a zero-sized frame and an effectively infinite text
            // container. Give it a content-sized horizontal extent before reflecting the
            // scroll position so the first character is at the visible origin.
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let width = max(scroll.contentSize.width, ceil(used.maxX + view.textContainerInset.width * 2))
            let height = max(scroll.contentSize.height, ceil(used.maxY + view.textContainerInset.height * 2))
            view.setFrameSize(NSSize(width: width, height: height))
            (scroll as? PreviewScrollView)?.resetOrigin = true
            scroll.needsLayout = true
        }
        (scroll.verticalRulerView as? LineNumberRuler)?.setText(text)
    }
}

private final class PreviewScrollView: NSScrollView {
    var resetOrigin = false

    override func layout() {
        super.layout()
        guard resetOrigin else { return }
        resetOrigin = false
        // Rulers alter the clip view's insets during tiling. Clamp against the
        // final geometry instead of treating (0, 0) as the scrollable origin.
        var proposed = contentView.bounds
        proposed.origin = NSPoint(x: -1_000_000, y: -1_000_000)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }
}

private final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var starts: [Int] = [0]
    private var observer: NSObjectProtocol?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 42
        scrollView.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
    }
    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setText(_ text: String) {
        starts = [0]
        for (offset, value) in text.utf16.enumerated() where value == 10 { starts.append(offset + 1) }
        ruleThickness = max(42, CGFloat(String(starts.count).count * 8 + 20))
        needsDisplay = true
    }

    private func lineNumber(for character: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= character { low = middle + 1 } else { high = middle }
        }
        return max(low, 1)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, glyphRange, _ in
            let character = layout.characterIndexForGlyph(at: glyphRange.location)
            let number = self.lineNumber(for: character)
            let label = String(number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            let size = label.size(withAttributes: attributes)
            let y = lineRect.minY + textView.textContainerInset.height - visible.minY
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 12, y: y + 1), withAttributes: attributes)
        }
    }
}
