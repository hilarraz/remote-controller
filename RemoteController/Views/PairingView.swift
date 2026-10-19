import SwiftUI

/// Sheet asking for the PIN the Apple TV displays during pairing.
struct PairingView: View {
    @Bindable var flow: PairingFlow
    var onCancel: () -> Void

    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Jumeler « \(flow.device.name) »")
                .font(.title2.bold())

            Group {
                switch flow.step {
                case .starting:
                    ProgressView("Connexion à l'Apple TV…")
                case .waitingForPIN, .verifying:
                    VStack(spacing: 12) {
                        Text("Saisissez le code à 4 chiffres affiché sur votre téléviseur.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        TextField("0000", text: $flow.pin)
                            .font(.system(size: 32, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .focused($pinFocused)
                            .disabled(flow.step == .verifying)
                            .onChange(of: flow.pin) { _, newValue in
                                let digits = String(newValue.filter(\.isNumber).prefix(4))
                                if digits != newValue { flow.pin = digits }
                                if digits.count == 4 { flow.submit() }
                            }
                            .onSubmit { flow.submit() }
                        if flow.step == .verifying {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .onAppear { pinFocused = true }
                case .failed(let message):
                    VStack(spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                        Button("Réessayer", systemImage: "arrow.clockwise") { flow.begin() }
                            .buttonStyle(.glass)
                    }
                }
            }
            .frame(minHeight: 110)

            HStack {
                Button("Annuler", role: .cancel) {
                    flow.cancel()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Jumeler") { flow.submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(flow.step != .waitingForPIN || flow.pin.count != 4)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}
