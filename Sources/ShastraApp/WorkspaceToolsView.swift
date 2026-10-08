import AppKit
import Darwin
import PDFKit
import SwiftUI
import ShastraCore
import SwiftTerm

@MainActor
final class WorkspaceToolsModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case files = "Files"
        case preview = "Preview"
        case terminal = "Terminal"
        case browser = "Browser"
        case changes = "Changes"
        case inspector = "Info"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .files: "folder"
            case .preview: "eye"
            case .terminal: "terminal"
            case .browser: "globe"
            case .changes: "arrow.triangle.branch"
            case .inspector: "sidebar.right"
            }
        }
    }

    @Published var tab: Tab = .files
    @Published var selectedFile: URL?
    @Published var openedFiles: [URL] = []
    @Published var showsExplorer = true
    @Published var root = FileManager.default.homeDirectoryForCurrentUser
    @Published var showHidden = false
    @Published var refreshToken = UUID()
    @Published var terminal: TerminalSession?
    let browser = BrowserState()

    func setRoot(_ path: String) {
        let newRoot = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard newRoot != root else { return }
        terminal?.stop()
        terminal = nil
        root = newRoot
        selectedFile = nil
        openedFiles = []
        tab = .files
        refreshToken = UUID()
    }

    func select(_ file: URL) {
        selectedFile = file
        showsExplorer = false
        if !openedFiles.contains(file) { openedFiles.append(file) }
        tab = .preview
    }

    func close(_ file: URL) {
        openedFiles.removeAll { $0 == file }
        if selectedFile == file { selectedFile = openedFiles.last }
    }

    func openTerminal() {
        if terminal == nil { terminal = TerminalSession(directory: root) }
        tab = .terminal
    }
}

struct WorkspaceToolsView: View {
    @ObservedObject var tools: WorkspaceToolsModel
    let conversation: Conversation

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    appTab("Files", symbol: "doc", selected: (tools.tab == .files || tools.tab == .preview) && tools.selectedFile == nil) {
                        tools.showsExplorer = true
                        tools.tab = tools.selectedFile == nil ? .files : .preview
                    }
                    ForEach(tools.openedFiles, id: \.self) { file in
                        HStack(spacing: 8) {
                            Button { tools.selectedFile = file; tools.tab = .preview } label: {
                                Label(file.lastPathComponent, systemImage: FileIcon.symbol(for: file))
                                    .font(.system(size: 12)).lineLimit(1)
                            }.buttonStyle(.plain)
                            Button { tools.close(file) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                                .buttonStyle(.plain).help("Close \(file.lastPathComponent)")
                        }
                        .foregroundStyle(tools.selectedFile == file && tools.tab == .preview ? Surface.text : Surface.muted)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(tools.selectedFile == file && tools.tab == .preview ? Surface.selected.opacity(0.55) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                    }
                    appTab("Browser", symbol: "globe", selected: tools.tab == .browser) { tools.tab = .browser }
                    appTab("Changes", symbol: "arrow.triangle.branch", selected: tools.tab == .changes) { tools.tab = .changes }
                    appTab("Terminal", symbol: "terminal", selected: tools.tab == .terminal) { tools.openTerminal() }
                    appTab("Info", symbol: "info.circle", selected: tools.tab == .inspector) { tools.tab = .inspector }
                }.padding(.horizontal, Design.headerInset)
            }.frame(height: Design.headerHeight)
                .overlay(alignment: .bottom) { Surface.stroke.opacity(0.6).frame(height: 1) }
            Group {
                switch tools.tab {
                case .files, .preview:
                    VStack(spacing: 0) {
                        if tools.selectedFile != nil {
                        HStack(spacing: 6) {
                            Text(tools.root.lastPathComponent)
                            if let file = tools.selectedFile {
                                Image(systemName: "chevron.right").font(.system(size: 8))
                                Text(file.path.hasPrefix(tools.root.path + "/")
                                    ? String(file.path.dropFirst(tools.root.path.count + 1)) : file.path)
                                    .lineLimit(1).truncationMode(.middle).help(file.path)
                            }
                            Spacer()
                            Button { tools.showsExplorer.toggle() } label: { Image(systemName: "sidebar.right") }
                                .buttonStyle(.plain).help(tools.showsExplorer ? "Hide file explorer" : "Browse files")
                        }.font(.system(size: 11)).foregroundStyle(Surface.muted)
                            .padding(.horizontal, 14).frame(height: 34)
                        Surface.stroke.frame(height: 1)
                        }
                        if tools.selectedFile == nil {
                            FileBrowserView(tools: tools).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                        HSplitView {
                            FilePreviewView(file: tools.selectedFile)
                                .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                            if tools.showsExplorer {
                                FileBrowserView(tools: tools)
                                    .frame(minWidth: 155, idealWidth: 195, maxWidth: 260)
                            }
                        }
                        }
                    }
                case .terminal:
                    if let terminal = tools.terminal { TerminalPane(session: terminal) }
                case .browser: NativeBrowserPane(browser: tools.browser)
                case .changes: GitChangesPane(root: tools.root, onPreview: tools.select)
                case .inspector: InspectorPane(conversation: conversation)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Surface.dock)
    }

    private func appTab(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if selected { Text(title) }
            }
                .font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(selected ? Surface.accent : Surface.muted)
                .padding(.horizontal, 10).frame(height: 28)
                .background(selected ? Surface.selected.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
}

enum FileIcon {
    static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "h": "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml": "curlybraces"
        case "md", "txt": "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": "photo"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }
}

private struct FileBrowserView: View {
    @ObservedObject var tools: WorkspaceToolsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Surface.muted)
                Text(tools.root.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                Button { tools.showHidden.toggle(); tools.refreshToken = UUID() } label: {
                    Image(systemName: tools.showHidden ? "eye" : "eye.slash")
                }.help(tools.showHidden ? "Hide hidden files" : "Show hidden files")
                Button { tools.refreshToken = UUID() } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("Refresh files")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11)).foregroundStyle(Surface.muted)
            .padding(.horizontal, 12).frame(height: 36)
            Divider()
            ScrollView {
                FileTreeRow(url: tools.root, depth: 0, showHidden: tools.showHidden,
                            selected: tools.selectedFile, onSelect: tools.select)
                    .id(tools.refreshToken)
                    .padding(.vertical, 8)
            }
            .overlay {
                if !FileManager.default.fileExists(atPath: tools.root.path) {
                    ContentUnavailableView("Workspace unavailable", systemImage: "folder.badge.questionmark",
                                           description: Text(tools.root.path))
                }
            }
        }
    }
}

@MainActor private final class FileTreeState: ObservableObject {
    @Published var expanded = false
    @Published var children: [URL] = []
    @Published var isLoading = false
    private var loadID = UUID()

    func expand(url: URL, showHidden: Bool) {
        expanded = true
        isLoading = true
        loadID = UUID()
        let requestID = loadID
        Task {
            let result = await Task.detached(priority: .utility) {
                FileTreeRow.contents(of: url, showHidden: showHidden)
            }.value
            guard requestID == loadID else { return }
            children = result
            isLoading = false
        }
    }

    func toggle(url: URL, showHidden: Bool) {
        if expanded { expanded = false }
        else { expand(url: url, showHidden: showHidden) }
    }
}

private struct FileTreeRow: View {
    let url: URL
    let depth: Int
    let showHidden: Bool
    let selected: URL?
    let onSelect: (URL) -> Void
    @StateObject private var state = FileTreeState()

    private var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if isDirectory {
                    Image(systemName: state.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                } else {
                    Color.clear.frame(width: 14)
                }
                Image(systemName: isDirectory ? "folder" : FileIcon.symbol(for: url))
                    .font(.system(size: 12)).foregroundStyle(Surface.muted).frame(width: 15)
                Text(depth == 0 ? url.lastPathComponent : url.lastPathComponent)
                    .font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth * 13 + 10))
            .padding(.trailing, 10).frame(height: 27)
            .background(selected == url ? Surface.selected.opacity(0.65) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(url.lastPathComponent)
            .accessibilityValue(isDirectory ? (state.expanded ? "Expanded folder" : "Collapsed folder") : "File")
            .accessibilityAddTraits(.isButton)
            .onTapGesture {
                if isDirectory {
                    state.toggle(url: url, showHidden: showHidden)
                } else { onSelect(url) }
            }
            if state.expanded {
                if state.isLoading {
                    Text("Loading folder…").font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, CGFloat((depth + 1) * 13 + 30)).padding(.vertical, 5)
                } else if state.children.isEmpty {
                    Text("Empty folder").font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, CGFloat((depth + 1) * 13 + 30)).padding(.vertical, 5)
                } else {
                    ForEach(state.children, id: \.self) { child in
                        FileTreeRow(url: child, depth: depth + 1, showHidden: showHidden,
                                    selected: selected, onSelect: onSelect)
                    }
                }
            }
        }
        .padding(.horizontal, 5)
        .onAppear {
            if depth == 0 && !state.expanded {
                state.expand(url: url, showHidden: showHidden)
            }
        }
    }

    fileprivate nonisolated static func contents(of folder: URL, showHidden: Bool) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: options)) ?? []
        return urls.filter { showHidden || !["node_modules", ".build", "Pods"].contains($0.lastPathComponent) }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let right = (try? $1.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return left == right ? $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending : left
            }
    }
}

@MainActor private final class FilePreviewState: ObservableObject {
    @Published var text: String?
    @Published var image: NSImage?
    @Published var pdfDocument: PDFDocument?
    @Published var error: String?
    @Published var isLoading = false
    var requestID = UUID()
}

private struct FilePreviewView: View {
    let file: URL?
    @StateObject private var state = FilePreviewState()

    var body: some View {
        Group {
            if let file {
                VStack(spacing: 0) {
                    if file.pathExtension.lowercased() == "pdf" {
                        if let document = state.pdfDocument {
                            NativePDFPreview(document: document)
                        } else if state.isLoading {
                            ProgressView("Loading PDF…").frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            unavailable(file)
                        }
                    } else if state.isLoading {
                        ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = state.error {
                        VStack(spacing: 10) {
                            ContentUnavailableView("Preview unavailable", systemImage: "doc.questionmark",
                                                   description: Text(error))
                            Button("Open in Default App") { NSWorkspace.shared.open(file) }
                                .buttonStyle(.plain)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let image = state.image {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(15)
                        }
                    } else if let text = state.text {
                        NativeTextPreview(text: text, language: file.pathExtension)
                    } else {
                        unavailable(file)
                    }
                }
                .task(id: file) { await load(file) }
            } else {
                VStack(spacing: 15) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 38, weight: .ultraLight))
                        .foregroundStyle(Surface.muted.opacity(0.4))
                    Text("Your workspace").font(.system(size: 16, weight: .medium)).foregroundStyle(Surface.muted)
                    Text("Select a file to open a tab.\nImages and PDFs open here too.")
                        .font(.system(size: 12)).lineSpacing(4).foregroundStyle(Surface.muted.opacity(0.8))
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func load(_ file: URL) async {
        let requestID = UUID()
        state.requestID = requestID
        state.text = nil; state.image = nil; state.pdfDocument = nil; state.error = nil
        state.isLoading = true
        defer { if state.requestID == requestID { state.isLoading = false } }
        let result = await Task.detached(priority: .utility) {
            FilePreviewLoader.read(file)
        }.value
        guard !Task.isCancelled, state.requestID == requestID else { return }
        switch result {
        case .pdf(let data):
            guard let document = PDFDocument(data: data) else {
                state.error = "This PDF is damaged or unsupported."
                return
            }
            state.pdfDocument = document
        case .image(let data):
            guard let image = NSImage(data: data) else { state.error = "Image is unreadable"; return }
            state.image = image
        case .text(let text): state.text = text
        case .error(let message): state.error = message
        }
    }

    @ViewBuilder private func unavailable(_ file: URL) -> some View {
        VStack(spacing: 10) {
            ContentUnavailableView("Preview unavailable", systemImage: "doc.questionmark",
                                   description: Text(state.error ?? "This file cannot be previewed."))
            Button("Open in Default App") { NSWorkspace.shared.open(file) }
                .buttonStyle(.plain)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum FilePreviewLoader {
    enum Result: Sendable { case pdf(Data), image(Data), text(String), error(String) }

    static func read(_ file: URL) -> Result {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey]),
              let size = values.fileSize else { return .error("File is unavailable") }
        if file.pathExtension.lowercased() == "pdf" {
            guard let data = try? Data(contentsOf: file) else { return .error("PDF file is unavailable") }
            return .pdf(data)
        }
        if values.contentType?.conforms(to: .image) == true {
            guard size <= 30_000_000, let data = try? Data(contentsOf: file) else {
                return .error("Image is too large or unreadable")
            }
            return .image(data)
        }
        guard size <= 2_000_000, let data = try? Data(contentsOf: file),
              !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .error("Binary or large file")
        }
        return .text(text)
    }
}

private struct NativePDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .textBackgroundColor
        view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

@MainActor
final class TerminalSession: ObservableObject {
    @Published var isRunning = false
    @Published var error: String?
    let directory: URL
    fileprivate let view = ManagedTerminalView(frame: .zero)

    init(directory: URL) {
        self.directory = directory
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.configureNativeColors()
        view.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.processDidTerminate() }
        }
    }

    isolated deinit { view.shutdownImmediately() }

    func start() {
        guard !isRunning else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "Workspace folder is unavailable: \(directory.path)"
            return
        }
        error = nil
        view.startProcess(executable: "/bin/zsh", args: ["-i"], currentDirectory: directory.path)
        isRunning = view.isRunning
    }

    func interrupt() {
        guard isRunning else { return }
        view.send(source: view, data: ArraySlice([UInt8(3)]))
    }

    func stop() {
        view.signalHangup()
    }

    func updateNativeColors() { view.configureNativeColors() }

    fileprivate func processDidTerminate() {
        isRunning = false
    }
}

private final class ManagedTerminalView: TerminalView, @preconcurrency TerminalViewDelegate, @preconcurrency LocalProcessDelegate {
    private var process: LocalProcess!
    private var shutdownTask: Task<Void, Never>?
    var terminationHandler: ((Int32?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        process = LocalProcess(delegate: self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminalDelegate = self
        process = LocalProcess(delegate: self)
    }

    var isRunning: Bool { process.running }

    func startProcess(executable: String, args: [String], currentDirectory: String) {
        guard !process.running else { return }
        shutdownTask?.cancel()
        shutdownTask = nil
        process.startProcess(executable: executable, args: args, currentDirectory: currentDirectory)
    }

    func signalHangup() {
        let pid = process.shellPid
        // The PID comes directly from our owned forkpty child. Its process group
        // can still be changing during startup, so it is not a readiness check.
        guard process.running, pid > 1 else { return }
        _ = kill(pid, SIGHUP)
        shutdownTask?.cancel()
        shutdownTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self, !Task.isCancelled,
                  self.process.running, self.process.shellPid == pid else { return }
            _ = kill(pid, SIGKILL)
        }
    }

    func shutdownImmediately() {
        shutdownTask?.cancel()
        shutdownTask = nil
        guard process.running, process.shellPid > 1 else { return }
        _ = kill(process.shellPid, SIGKILL)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard process.running else { return }
        var size = getWindowSize()
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { process.send(data: data) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([string as NSString])
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func dataReceived(slice: ArraySlice<UInt8>) { feed(byteArray: slice) }
    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(max(0, terminal.rows)), ws_col: UInt16(max(0, terminal.cols)),
                ws_xpixel: UInt16(max(0, frame.width)), ws_ypixel: UInt16(max(0, frame.height)))
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        shutdownTask?.cancel()
        shutdownTask = nil
        terminationHandler?(exitCode)
    }
}

private struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(session.isRunning ? .green : .secondary).frame(width: 7, height: 7)
                Text(session.directory.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                if session.isRunning {
                    Button("Interrupt") { session.interrupt() }.help("Send Control-C")
                    Button("Stop") { session.stop() }
                } else {
                    Button("Start shell") { session.start() }
                }
            }
            .font(.caption).buttonStyle(.plain).padding(12)
            Divider()
            if let error = session.error {
                ContentUnavailableView("Terminal unavailable", systemImage: "terminal",
                                       description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeTerminalView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { session.updateNativeColors(); session.start() }
        .onChange(of: colorScheme) { _, _ in session.updateNativeColors() }
    }
}

private struct NativeTerminalView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView(terminal: session.view)
    }
    func updateNSView(_ view: TerminalContainerView, context: Context) { view.needsLayout = true }
}

private final class TerminalContainerView: NSView {
    let terminal: ManagedTerminalView
    init(terminal: ManagedTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.removeFromSuperview()
        addSubview(terminal)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        if terminal.frame != bounds { terminal.frame = bounds }
    }
}
