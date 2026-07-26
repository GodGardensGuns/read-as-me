import SwiftUI

struct SourceTextReviewView: View {
    @ObservedObject var controller: AudiobookController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review Source Text")
                        .font(.title2.weight(.semibold))
                    Text("Nothing changes in the original book. Accepted corrections apply only to this audiobook.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select All") {
                    controller.acceptAllSourceSuggestions()
                }
                Button("Select None") {
                    controller.clearAllSourceSuggestions()
                }
            }
            .padding(20)

            Divider()

            List(controller.sourceTextSuggestions) { suggestion in
                Toggle(
                    isOn: Binding(
                        get: {
                            controller.sourceTextSuggestions.first(where: { $0.id == suggestion.id })?.accepted ?? false
                        },
                        set: { controller.setSourceSuggestion(suggestion.id, accepted: $0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(suggestion.message)
                            .font(.headline)
                        HStack {
                            Text(suggestion.original)
                                .strikethrough()
                                .foregroundStyle(.red)
                            Image(systemName: "arrow.right")
                            Text(suggestion.replacement)
                                .foregroundStyle(.green)
                        }
                        .font(.system(.body, design: .monospaced))
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            HStack {
                Button("Continue Without Changes") {
                    controller.finishSourceTextReview(applySelected: false)
                }
                Spacer()
                Text("\(controller.sourceTextSuggestions.filter(\.accepted).count) selected")
                    .foregroundStyle(.secondary)
                Button("Apply Selected and Continue") {
                    controller.finishSourceTextReview(applySelected: true)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
    }
}
