import AppKit
import SwiftUI
import WebKit

@MainActor final class BrowserState: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var address = ""
    @Published var isLoaded = false
    @Published var error: String?
    @Published var navigationTick = 0
    @Published var isLoading = false
    let webView = WKWebView(frame: .zero)

    override init() {
        super.init()
        webView.navigationDelegate = self
    }

    func navigate() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let normalized: String
        if value.contains("://") { normalized = value }
        else if value.hasPrefix("localhost") || value.hasPrefix("127.0.0.1") {
            normalized = "http://" + value
        } else { normalized = "https://" + value }
        guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme ?? ""),
              url.host != nil else { error = "Enter a valid web address"; return }
        address = url.absoluteString
        error = nil
        isLoaded = true
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        address = webView.url?.absoluteString ?? address
        isLoading = false
        error = nil
        navigationTick += 1
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        error = nil
        navigationTick += 1
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) {
        navigationFailed(failure)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) {
        navigationFailed(failure)
    }

    private func navigationFailed(_ failure: Error) {
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        isLoading = false
        error = failure.localizedDescription
        navigationTick += 1
    }
}

struct NativeBrowserPane: View {
    @ObservedObject var browser: BrowserState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                let _ = browser.navigationTick
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.webView.canGoBack).help("Back")
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.webView.canGoForward).help("Forward")
                TextField("URL or localhost:3000", text: $browser.address)
                    .font(.system(size: 11)).textFieldStyle(.roundedBorder)
                    .onSubmit { browser.navigate() }
                    .accessibilityLabel("Web address")
                Button { browser.navigate() } label: { Image(systemName: "arrow.right") }
                    .help("Open address").accessibilityLabel("Open address")
                Button {
                    if browser.error != nil { browser.navigate() }
                    else { browser.webView.reload() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!browser.isLoaded).help("Reload")
                if browser.error == nil, let url = browser.webView.url {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "arrow.up.right.square")
                    }.help("Open in default browser").accessibilityLabel("Open in default browser")
                }
                if browser.isLoading { ProgressView().controlSize(.mini) }
            }
            .buttonStyle(.plain).padding(10)
            Divider()
            if let error = browser.error {
                ContentUnavailableView {
                    Label("Couldn't open page", systemImage: "globe.badge.chevron.backward")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { browser.navigate() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.isLoaded {
                BrowserWebView(webView: browser.webView)
            } else {
                ContentUnavailableView("Browser", systemImage: "globe",
                    description: Text("Open a website or local development server beside your conversation."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView {
        webView.removeFromSuperview()
        return webView
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
