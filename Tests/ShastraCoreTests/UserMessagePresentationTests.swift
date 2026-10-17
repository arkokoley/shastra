import Testing
@testable import ShastraCore

@Test func browserEnvelopeDoesNotHideTheActualRequest() {
    let envelope = "<in-app-browser-context source=\"ambient-ui-state\">\nBrowser metadata\n</in-app-browser-context>"
    let raw = "\n" + envelope + "\n\n## My request:\n\nFix the layout. श"
    let presentation = UserMessagePresentation(raw)
    #expect(presentation.text == "Fix the layout. श")
    #expect(presentation.browserContext == envelope)
}

@Test func quotedOrIncompleteContextRemainsVisible() {
    for raw in ["Explain this:\n<in-app-browser-context>example</in-app-browser-context>",
                "```\n<in-app-browser-context>example</in-app-browser-context>\n```",
                "<in-app-browser-context source=\"ambient-ui-state\">unfinished",
                "## My request:\nThis is ordinary text"] {
        #expect(UserMessagePresentation(raw).text == raw)
        #expect(UserMessagePresentation(raw).browserContext == nil)
    }
}

@Test func contextOnlyAndHeadinglessMessagesKeepAllContent() {
    let context = "<in-app-browser-context>Metadata</in-app-browser-context>"
    #expect(UserMessagePresentation(context).text.isEmpty)
    #expect(UserMessagePresentation(context).browserContext == context)
    #expect(UserMessagePresentation(context + "\nKeep this request").text == "Keep this request")
}
