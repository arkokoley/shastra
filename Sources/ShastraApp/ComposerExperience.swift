import AppKit
import SwiftUI
import ShastraCore
import UniformTypeIdentifiers

@MainActor private final class ComposerAccessoryState: ObservableObject {
    @Published var choosingFile = false
    @Published var fileQuery = ""
    @Published var files: [WorkspaceFileMatch] = []
    @Published var choosingModel = false
    @Published var modelQuery = ""
}

struct ComposerContextBar: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var ui = ComposerAccessoryState()
    let key: String
    let workspace: String
    @Binding var draft: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let files = app.experience.attachments[key], !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { file in
                            HStack(spacing: 6) {
                                Button { NSWorkspace.shared.open(URL(fileURLWithPath: file)) } label: {
                                    Label(URL(fileURLWithPath: file).lastPathComponent, systemImage: FileIcon.symbol(for: URL(fileURLWithPath: file)))
                                }.buttonStyle(.plain).help(file)
                                Button { app.experience.attachments[key]?.removeAll { $0 == file } } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).help("Remove attachment")
                            }.font(.caption).padding(7).background(Surface.selected, in: Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                Button { ui.choosingFile = true } label: { Label("Reference file", systemImage: "at") }.buttonStyle(.plain)
                Button { browse() } label: { Image(systemName: "paperclip") }.buttonStyle(.plain).help("Attach files")
                Button { app.pasteContextImage(key: key) } label: { Label("Paste image", systemImage: "photo") }.buttonStyle(.plain)
                Spacer()
            }.font(.system(size: 11)).foregroundStyle(Surface.muted)
        }
        .popover(isPresented: $ui.choosingFile) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Find a workspace file…", text: $ui.fileQuery).textFieldStyle(.roundedBorder)
                ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(ui.files) { file in
                        Button(file.relativePath) { app.addContextFiles([file.url], key: key); ui.choosingFile = false; removeMention() }
                            .buttonStyle(.plain).lineLimit(2)
                    }
                    if ui.files.isEmpty { Text(ui.fileQuery.isEmpty ? "Type a filename" : "No matching files").foregroundStyle(Surface.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 240)
            }.padding(14).frame(width: 380)
                .task(id: ui.fileQuery) {
                    let found = await WorkspaceFileSearch.search(root: URL(fileURLWithPath: workspace), query: ui.fileQuery)
                    guard !Task.isCancelled else { return }; ui.files = found
                }
        }
        .onChange(of: draft) { _, text in
            if text == "@" || text.hasSuffix(" @") || text.hasSuffix("\n@") { ui.fileQuery = ""; ui.choosingFile = true }
        }
    }
    private func removeMention() { if draft.hasSuffix("@") { draft.removeLast() } }
    private func browse() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if !workspace.isEmpty { panel.directoryURL = URL(fileURLWithPath: workspace) }
        if panel.runModal() == .OK { app.addContextFiles(panel.urls, key: key) }
    }
}

struct ComposerImagePaste: ViewModifier {
    @EnvironmentObject private var app: AppModel
    let key: String
    func body(content: Content) -> some View {
        content.onPasteCommand(of: [.image]) { _ in app.pasteContextImage(key: key) }
    }
}
