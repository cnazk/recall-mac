import RecallOTP
import SwiftUI

/// Adds a two-factor account by hand, for services that print the secret instead of
/// showing a QR code.
struct ManualAccountSheet: View {
    @Bindable var model: OTPModel

    @State private var issuer = ""
    @State private var account = ""
    @State private var secret = ""
    @State private var digits = 6
    @State private var period = 30
    @State private var algorithm = OTPAlgorithm.sha1
    @State private var showsAdvanced = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an account").font(.headline)

            Form {
                TextField("Service", text: $issuer, prompt: Text("GitHub"))
                TextField("Account", text: $account, prompt: Text("alex@example.com"))
                TextField("Secret", text: $secret, prompt: Text("JBSWY3DPEHPK3PXP"))
                    .font(.body.monospaced())

                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    Picker("Algorithm", selection: $algorithm) {
                        ForEach(OTPAlgorithm.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Digits", selection: $digits) {
                        Text("6").tag(6)
                        Text("7").tag(7)
                        Text("8").tag(8)
                    }
                    Picker("Rotates every", selection: $period) {
                        Text("30 seconds").tag(30)
                        Text("60 seconds").tag(60)
                    }
                }
            }
            .formStyle(.grouped)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty || account.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func add() {
        // Validated here rather than in the helper, so a typo is caught while the field
        // that caused it is still on screen.
        guard let decoded = Base32.decode(secret), !decoded.isEmpty else {
            problem = "That secret is not valid base32. It should look like JBSWY3DPEHPK3PXP."
            return
        }

        let draft = OTPAccount(
            issuer: issuer.trimmingCharacters(in: .whitespaces),
            account: account.trimmingCharacters(in: .whitespaces),
            secret: decoded,
            algorithm: algorithm,
            digits: digits,
            period: period
        )

        Task {
            // Handed over as a URI, so manual entry goes through exactly the same import
            // path as a scanned QR code — one road into the helper, not two.
            if await model.importURI(OTPURI.string(for: draft)) > 0 {
                dismiss()
            } else {
                problem = model.failure ?? "That account could not be added."
            }
        }
    }
}
