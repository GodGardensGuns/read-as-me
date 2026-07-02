import SwiftUI

struct VoicePickerView: View {
    @ObservedObject var controller: AudiobookController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Voice", systemImage: "person.wave.2")
                    .font(.headline)
                Spacer()
                Button {
                    controller.clearVoiceSelection()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Clear voice selection")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Sample")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PathField(text: controller.voiceSampleURL?.path ?? "No voice sample selected")
                Button {
                    controller.chooseVoiceSample()
                } label: {
                    Label("Choose Audio", systemImage: "waveform.badge.plus")
                        .frame(maxWidth: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Transcript Mode", selection: $controller.voiceTranscriptMode) {
                    ForEach(TranscriptInputMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch controller.voiceTranscriptMode {
                case .file:
                    Text("Source")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    PathField(text: controller.voiceTranscriptURL?.path ?? "No transcript file selected")

                    Button {
                        controller.chooseVoiceTranscript()
                    } label: {
                        Label("Choose Text", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }

                case .text:
                    Text("Text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $controller.voiceTranscriptText)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .padding(6)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
