import AppleTVKit
import SwiftUI

/// Mirrors the text field focused on the Apple TV: whatever is typed here appears on
/// the TV as you type.
struct KeyboardPanel: View {
    let model: RemoteModel
    let session: TextInputSession
    var onClose: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(session.title ?? "Saisie de texte", systemImage: "keyboard")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Fermer", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Masquer le clavier")
            }

            TextField(session.placeholder ?? "Tapez ici…", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($isFocused)
                .onChange(of: text) { _, newValue in
                    model.updateText(newValue)
                }
                .onSubmit {
                    isFocused = false
                    onClose()
                }

            HStack {
                Button("Coller", systemImage: "doc.on.clipboard") {
                    model.pasteClipboard()
                }
                .help("Coller le presse-papiers du Mac sur l'Apple TV (⌘V)")
                Button("Effacer", systemImage: "delete.left") {
                    text = ""
                    model.clearText()
                }
                Spacer()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .onAppear {
            text = session.text
            isFocused = true
        }
        .onChange(of: session.sessionUUID) {
            text = session.text
            isFocused = true
        }
        .onChange(of: session.text) { _, newValue in
            // Text pasted from elsewhere (e.g. the global shortcut) shows up here too.
            if newValue != text { text = newValue }
        }
    }
}
