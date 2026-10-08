import AppKit
import SwiftUI

private struct ChangedFile: Identifiable, Sendable {
    let status: String
    let path: String
    var id: String { path }
}

@MainActor private final class GitChangesState: ObservableObject {
    @Published var files: [ChangedFile] = []
    @Published var selectedPath: String?
    @Published var diff = ""
    @Published var message: String?
    @Published var repositoryRoot: URL?
    @Published var isLoading = false
    private var refreshID = UUID()
    private var selectionID = UUID()

    func refresh(directory: URL) {
        refreshID = UUID()
        selectionID = UUID()
        let requestID = refreshID
        isLoading = true
        message = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                GitChangesLoader.status(directory: directory)
            }.value
            guard requestID == refreshID else { return }
            isLoading = false
            switch result {
            case .failure(let error):
                repositoryRoot = nil; files = []; selectedPath = nil; diff = ""
                message = error
            case .success(let status):
                repositoryRoot = status.root
                files = status.files
                message = status.files.isEmpty ? "Working tree clean" : nil
                if let selectedPath, status.files.contains(where: { $0.path == selectedPath }) {
                    select(selectedPath)
                } else if let first = status.files.first { select(first.path) }
                else { selectedPath = nil; diff = "" }
            }
        }
    }

    func select(_ path: String) {
        guard let root = repositoryRoot else { return }
        selectionID = UUID()
        selectedPath = path
        if let file = files.first(where: { $0.path == path }), file.status == "??" {
            diff = "Untracked file. Open it in Preview to read its contents."
        } else {
            let requestID = selectionID
            diff = "Loading diff…"
            Task {
                let result = await Task.detached(priority: .utility) {
                    GitChangesLoader.diff(root: root, path: path)
                }.value
                guard requestID == selectionID, selectedPath == path else { return }
                diff = result
            }
        }
    }
}

private enum GitChangesLoader {
    struct Status: Sendable { let root: URL; let files: [ChangedFile] }
    enum Outcome: Sendable { case success(Status), failure(String) }

    static func status(directory: URL) -> Outcome {
        guard let rootData = run(["-C", directory.path, "rev-parse", "--show-toplevel"]),
              let rootString = String(data: rootData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rootString.isEmpty else { return .failure("This workspace is not in a Git repository.") }
        let root = URL(fileURLWithPath: rootString, isDirectory: true)
        guard let data = run(["-C", root.path, "status", "--porcelain=v1", "-z", "--untracked-files=normal"]) else {
            return .failure("Could not read Git status.")
        }
        let fields = data.split(separator: 0)
        var found: [ChangedFile] = []
        var index = 0
        while index < fields.count {
            let field = String(decoding: fields[index], as: UTF8.self)
            if field.count >= 4 {
                let status = String(field.prefix(2))
                let path = String(field.dropFirst(3))
                found.append(.init(status: status, path: path))
                if status.contains("R") || status.contains("C") { index += 1 }
            }
            index += 1
        }
        return .success(Status(root: root, files: found))
    }

    static func diff(root: URL, path: String) -> String {
        // `git diff HEAD` fails in repositories that do not have their first commit yet.
        let headExists = run(["-C", root.path, "rev-parse", "--verify", "HEAD"]) != nil
        let data: Data?
        if headExists {
            data = run(["-C", root.path, "diff", "HEAD", "--no-ext-diff", "--", path])
        } else {
            let unstaged = run(["-C", root.path, "diff", "--no-ext-diff", "--", path])
            let staged = run(["-C", root.path, "diff", "--cached", "--no-ext-diff", "--", path])
            if let unstaged, let staged { data = staged + unstaged } else { data = nil }
        }
        guard let data else { return "Could not load diff." }
        let full = String(decoding: data, as: UTF8.self)
        return full.isEmpty ? "No text diff available for this change." : String(full.prefix(300_000))
    }

    private static func run(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }
}

struct GitChangesPane: View {
    let root: URL
    let onPreview: (URL) -> Void
    @StateObject private var state = GitChangesState()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                Text("Changes").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(state.files.count)").font(.caption).foregroundStyle(.secondary)
                Button { state.refresh(directory: root) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh Git status")
            }
            .padding(12)
            Divider()
            if state.isLoading {
                ProgressView("Reading Git status…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = state.message {
                ContentUnavailableView(message,
                    systemImage: message == "Working tree clean" ? "checkmark.circle" : "folder.badge.questionmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(state.files) { file in
                            Button { state.select(file.path) } label: {
                                HStack(spacing: 8) {
                                    Text(file.status).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(file.status == "??" ? .green : .orange)
                                        .frame(width: 24)
                                    Text(file.path).font(.system(size: 11)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(state.selectedPath == file.path ? Color.accentColor.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(7)
                }
                .frame(maxHeight: 220)
                Divider()
                HStack {
                    Text(state.selectedPath ?? "Diff").font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if let path = state.selectedPath, !path.hasSuffix("/"), let repository = state.repositoryRoot {
                        Button("Preview") { onPreview(repository.appending(path: path)) }
                            .font(.caption).buttonStyle(.plain)
                    }
                }.padding(10)
                ScrollView([.horizontal, .vertical]) {
                    Text(state.diff).font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onAppear { state.refresh(directory: root) }
        .onChange(of: root) { _, value in state.refresh(directory: value) }
    }
}
