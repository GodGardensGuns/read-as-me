import SwiftUI

struct BookPickerView: View {
    @ObservedObject var controller: AudiobookController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Book", systemImage: "book")
                .font(.headline)

            PathField(text: controller.selectedBookURL?.path ?? "No book selected")

            Button {
                controller.chooseBook()
            } label: {
                Label("Choose EPUB, PDF, or TXT", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
