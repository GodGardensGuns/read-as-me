import SwiftUI

struct ConversionControlView: View {
    @ObservedObject var controller: AudiobookController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Convert", systemImage: "waveform.badge.plus")
                .font(.headline)

            Button {
                controller.convertSelectedBook()
            } label: {
                Label("Make Audiobook", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canConvert)

            if controller.conversionState.isBusy {
                Button {
                    controller.cancelConversion()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
            }

            if let latestOutputURL = controller.latestOutputURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latest Audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PathField(text: latestOutputURL.path)
                }
            }
        }
    }
}
