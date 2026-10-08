import ShastraCore
import SwiftUI

@MainActor private final class QuestionAnswers: ObservableObject {
    @Published var selected: [String: Set<String>] = [:]
    @Published var custom: [String: String] = [:]
}

struct QuestionCard: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = QuestionAnswers()
    let question: PendingQuestion

    private var answers: [String: [String]] {
        Dictionary(question.questions.map { item in
            let custom = (state.custom[item.prompt] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let selected = item.options.filter { state.selected[item.prompt, default: []].contains($0) }
            return (item.prompt, custom.isEmpty ? selected : item.multiSelect ? selected + [custom] : [custom])
        }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Claude needs your input", systemImage: "bubble.left.and.bubble.right").font(.system(size: 13, weight: .medium))
            ForEach(question.questions) { item in
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.header).font(.system(size: 11, weight: .medium)).foregroundStyle(Surface.muted)
                    Text(item.prompt).font(.system(size: 13)).textSelection(.enabled)
                    ForEach(item.options, id: \.self) { option in
                        Button {
                            if item.multiSelect {
                                if !state.selected[item.prompt, default: []].insert(option).inserted { state.selected[item.prompt]?.remove(option) }
                            } else { state.selected[item.prompt] = [option]; state.custom[item.prompt] = "" }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: state.selected[item.prompt, default: []].contains(option) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option).font(.system(size: 13, weight: .medium))
                                    if let detail = item.optionDescriptions[option], !detail.isEmpty {
                                        Text(detail).font(.system(size: 12)).foregroundStyle(Surface.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer()
                            }.padding(9).background(Surface.raised, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityLabel(option)
                    }
                    TextField("Write your own answer", text: Binding(get: { state.custom[item.prompt] ?? "" }, set: { state.custom[item.prompt] = $0 }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Answer: \(item.header)")
                }
            }
            HStack {
                Spacer()
                Button("Submit answers") { model.answer(question, answers: answers) }
                    .buttonStyle(.borderedProminent).disabled(answers.values.contains(where: \.isEmpty))
            }
        }.padding(18).background(Surface.selected.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
