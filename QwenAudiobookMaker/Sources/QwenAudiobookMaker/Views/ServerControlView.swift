import SwiftUI

struct ServerControlView: View {
    @ObservedObject var controller: AudiobookController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Qwen", systemImage: "cpu")
                .font(.headline)

            HStack {
                Button {
                    controller.startServer()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(controller.serverState != .stopped)

                Button {
                    controller.stopServer()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(controller.serverState == .stopped)
            }
        }
    }
}
