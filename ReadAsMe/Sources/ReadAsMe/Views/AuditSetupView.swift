import SwiftUI

struct AuditSetupView: View {
    @ObservedObject var controller: AudiobookController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Audiobook", systemImage: "waveform")
                    .font(.headline)
                PathField(text: controller.selectedAuditAudioURL?.path ?? "No audiobook selected")
                Button {
                    controller.chooseAuditAudio()
                } label: {
                    Label("Choose WAV, MP3, M4A, M4B, or FLAC", systemImage: "waveform.badge.plus")
                        .frame(maxWidth: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Expected Text", systemImage: "text.book.closed")
                        .font(.headline)
                    Spacer()
                    if controller.selectedExpectedTextURL != nil {
                        Button {
                            controller.clearExpectedText()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .help("Remove expected text")
                    }
                }
                Text("Optional. Add the book or transcript to detect missing and incorrect words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PathField(text: controller.selectedExpectedTextURL?.path ?? "No expected text selected")
                Button {
                    controller.chooseExpectedText()
                } label: {
                    Label("Choose EPUB, PDF, or TXT", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Quality Profile", systemImage: "dial.medium")
                    .font(.headline)
                Picker("Quality Profile", selection: $controller.qualityProfile) {
                    ForEach(QualityProfile.allCases) { profile in
                        Text(profile.rawValue).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if controller.qualityProfile == .acx {
                    Text("Technical targets only. This does not guarantee ACX acceptance or narration eligibility.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Also export repaired audio in the original format", isOn: $controller.outputSameFormat)
                    .font(.caption)
            }

            if !controller.auditModelNoticeAccepted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("First audit download", systemImage: "arrow.down.circle")
                        .font(.headline)
                    Text("NVIDIA Parakeet V3 needs about 2.5 GB. It runs locally and its first setup can take several minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Allow the local model download", isOn: $controller.auditModelNoticeAccepted)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            Button {
                controller.startExistingAudit()
            } label: {
                Label("Audit Audiobook", systemImage: "waveform.badge.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canStartExistingAudit)

            if controller.auditState.isBusy {
                Button {
                    controller.cancelQualityOperation()
                } label: {
                    Label("Cancel Audit", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
            }

            DisclosureGroup("Voice repair override") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ReadAsMe extracts a clean sample automatically when possible. Override it here for speech repairs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PathField(text: controller.voiceSampleURL?.path ?? "No manual voice sample")
                    Button {
                        controller.chooseVoiceSample()
                    } label: {
                        Label("Choose Voice Audio", systemImage: "person.wave.2")
                            .frame(maxWidth: .infinity)
                    }
                    PathField(text: controller.voiceTranscriptURL?.path ?? "No matching voice transcript")
                    Button {
                        controller.chooseVoiceTranscript()
                    } label: {
                        Label("Choose Matching Transcript", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 8)
            }

            Button(role: .destructive) {
                controller.removeAuditModelAndRuntime()
            } label: {
                Label("Remove Audit Model", systemImage: "externaldrive.badge.minus")
            }
            .font(.caption)
            .disabled(controller.auditState.isBusy)
        }
        .disabled(controller.conversionState.isBusy)
    }
}
