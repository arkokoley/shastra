import AppKit
import SwiftUI

/// Native text and selectable code blocks, with a measured reading rhythm.
struct MarkdownMessage: View {
    let text: String

    private struct Block: Identifiable {
        enum Kind { case paragraph, heading(Int), code(String), bullet(String), quote, rule, table([[String]]) }
        let id: Int
        let kind: Kind
        let text: String
    }

    private var blocks: [Block] {
        let lines = text.components(separatedBy: "\n")
        var result: [Block] = []
        var paragraph: [String] = []
        var i = 0
        func append(_ kind: Block.Kind, _ content: String) {
            result.append(Block(id: result.count, kind: kind, text: content))
        }
        func flush() {
            if !paragraph.isEmpty { append(.paragraph, paragraph.joined(separator: "\n")); paragraph = [] }
        }
        func cells(_ line: String) -> [String] {
            var pieces = line.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pieces.first == "" { pieces.removeFirst() }
            if pieces.last == "" { pieces.removeLast() }
            return pieces
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                append(.code(language), code.joined(separator: "\n"))
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed == "---" || trimmed == "***" {
                flush(); append(.rule, "")
            } else if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "),
                      trimmed[..<space].allSatisfy({ $0 == "#" }) {
                flush(); append(.heading(min(trimmed.distance(from: trimmed.startIndex, to: space), 6)),
                                String(trimmed[trimmed.index(after: space)...]))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush(); append(.bullet("•"), String(trimmed.dropFirst(2)))
            } else if let range = trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flush(); append(.bullet(String(trimmed[range]).trimmingCharacters(in: .whitespaces)), String(trimmed[range.upperBound...]))
            } else if trimmed.hasPrefix("> ") {
                flush(); append(.quote, String(trimmed.dropFirst(2)))
            } else if trimmed.contains("|"), i + 1 < lines.count,
                      lines[i + 1].contains("|"),
                      cells(lines[i + 1]).allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) {
                flush()
                var rows = [cells(trimmed)]
                i += 2
                while i < lines.count && lines[i].contains("|") {
                    rows.append(cells(lines[i])); i += 1
                }
                append(.table(rows), ""); i -= 1
            } else {
                paragraph.append(line)
            }
            i += 1
        }
        flush()
        return result
    }

    private func inline(_ value: String) -> Text {
        let parsed = try? AttributedString(markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(parsed ?? AttributedString(value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                switch block.kind {
                case .paragraph:
                    inline(block.text).lineSpacing(5).textSelection(.enabled)
                case .heading(let level):
                    inline(block.text)
                        .font(.system(size: level == 1 ? 24 : level == 2 ? 20 : 17, weight: .semibold))
                        .padding(.top, 6).textSelection(.enabled)
                case .code(let language):
                    NativeCodeBlock(language: language, code: block.text)
                case .bullet(let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(marker).foregroundStyle(Surface.muted).frame(minWidth: 15, alignment: .trailing)
                        inline(block.text).lineSpacing(4).textSelection(.enabled)
                    }.padding(.leading, 4)
                case .quote:
                    HStack(spacing: 13) {
                        RoundedRectangle(cornerRadius: 2).fill(Surface.muted).frame(width: 3)
                        inline(block.text).foregroundStyle(Surface.muted).lineSpacing(4).textSelection(.enabled)
                    }.fixedSize(horizontal: false, vertical: true)
                case .rule:
                    Surface.stroke.frame(height: 1).padding(.vertical, 4)
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 12) {
                            ForEach(rows.indices, id: \.self) { row in
                                GridRow {
                                    ForEach(rows[row].indices, id: \.self) { column in
                                        inline(rows[row][column])
                                            .font(.system(size: 13, weight: row == 0 ? .semibold : .regular))
                                            .frame(minWidth: 90, maxWidth: 260, alignment: .leading)
                                            .textSelection(.enabled)
                                    }
                                }
                                if row == 0 { Surface.stroke.frame(height: 1).gridCellColumns(rows[row].count) }
                            }
                        }.padding(16)
                    }.background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Surface.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeCodeBlock: View {
    let language: String
    let code: String
    @StateObject private var interaction = ViewInteractionModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language).font(.system(size: 11, weight: .medium))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    interaction.copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        interaction.copied = false
                    }
                } label: {
                    Label(interaction.copied ? "Copied" : "Copy code", systemImage: interaction.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }.buttonStyle(.plain)
            }.foregroundStyle(Surface.muted).padding(.horizontal, 16).frame(height: 37)
                .background(Surface.hover.opacity(0.5))
            ScrollView(.horizontal) {
                Text(code).font(.system(size: 12, design: .monospaced))
                    .lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }.background(Surface.code, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Surface.stroke))
    }
}
