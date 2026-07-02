import SwiftUI

struct OutputPickerView: View {
    @ObservedObject var controller: AudiobookController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Output", systemImage: "folder")
                .font(.headline)

            PathField(text: controller.outputFolderURL.path)

            HStack {
                Button {
                    controller.chooseOutputFolder()
                } label: {
                    Label("Choose", systemImage: "folder.badge.gearshape")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    controller.openOutputFolder()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Open output folder")
            }
        }
    }
}
