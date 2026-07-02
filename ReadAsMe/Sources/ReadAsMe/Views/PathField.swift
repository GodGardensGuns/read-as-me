import SwiftUI

struct PathField: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(text.hasPrefix("No ") ? .secondary : .primary)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
