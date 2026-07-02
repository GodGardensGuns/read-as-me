import SwiftUI

struct ProgressSummaryView: View {
    @ObservedObject var controller: AudiobookController
    let onShowLogs: () -> Void

    private var percent: Int {
        Int((min(max(controller.progressFraction, 0), 1) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Progress", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                Spacer()
                Button {
                    onShowLogs()
                } label: {
                    Label("Show Logs", systemImage: "doc.text.magnifyingglass")
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: controller.progressFraction, total: 1)
                    .controlSize(.large)

                HStack(alignment: .firstTextBaseline) {
                    Text("\(percent)%")
                        .font(.title.weight(.semibold))
                    Spacer()
                    if controller.totalChunks > 0 {
                        Text("\(controller.completedChunks)/\(controller.totalChunks) chunks")
                            .foregroundStyle(.secondary)
                    }
                }

                Text(controller.progressTitle)
                    .font(.title3.weight(.semibold))

                Text(controller.progressDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

            if let latestOutputURL = controller.latestOutputURL {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Latest Audio", systemImage: "music.note")
                        .font(.headline)
                    PathField(text: latestOutputURL.path)
                    Button {
                        controller.openLatestOutput()
                    } label: {
                        Label("Open Audio", systemImage: "play.circle")
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }
}

struct LogsSheetView: View {
    @ObservedObject var controller: AudiobookController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Logs", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
            }

            LogView(text: controller.logText)
        }
        .padding(20)
    }
}
