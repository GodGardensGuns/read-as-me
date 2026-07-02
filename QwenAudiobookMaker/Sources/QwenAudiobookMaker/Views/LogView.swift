import SwiftUI

struct LogView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "No activity yet." : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                    .id("log-end")
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: text) { _, _ in
                proxy.scrollTo("log-end", anchor: .bottom)
            }
        }
    }
}
