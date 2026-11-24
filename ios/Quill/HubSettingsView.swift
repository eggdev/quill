import QuillKit
import SwiftUI

/// The hub's address, and a check that this iPhone can reach it.
struct HubSettingsView: View {
    let library: Library

    @State private var address = HubSettings.storedAddress
    @State private var check: CheckState = .idle
    @FocusState private var editing: Bool
    @Environment(\.dismiss) private var dismiss

    private enum CheckState: Equatable {
        case idle
        case checking
        case done(HubClient.Check)
    }

    private var trimmed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: URL? { HubAddress.parse(trimmed) }
    private var isValid: Bool { trimmed.isEmpty || parsed != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("mac.tailnet.ts.net:8090", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($editing)
                        .onSubmit { save() }
                        .accessibilityLabel("Hub address")
                } header: {
                    Text("Hub address")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !isValid {
                            Text("That doesn't look like a web address.")
                                .foregroundStyle(.red)
                        }
                        Text(
                            "The address of the Mac that keeps your recordings, from Tailscale. Tailscale must be connected on this iPhone."
                        )
                        if let override = HubSettings.debugOverride {
                            Text("This debug build uses \(override.absoluteString) from QUILL_HUB_URL.")
                        }
                    }
                }

                Section {
                    Button {
                        Task { await runCheck() }
                    } label: {
                        HStack {
                            Text("Check Connection")
                            Spacer()
                            if check == .checking { ProgressView() }
                        }
                    }
                    .disabled(parsed == nil || check == .checking)

                    if case .done(let result) = check {
                        CheckResult(result: result)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .onChange(of: address) { check = .idle }
            .onAppear { if trimmed.isEmpty { editing = true } }
        }
    }

    private func save() {
        guard isValid else { return }
        let normalized = parsed?.absoluteString ?? ""
        if normalized != trimmed { address = normalized }
        guard normalized != HubSettings.storedAddress else { return }
        HubSettings.storedAddress = normalized
        library.hubAddressChanged()
    }

    private func runCheck() async {
        guard let url = parsed else { return }
        editing = false
        check = .checking
        check = .done(await HubClient.check(HubAPI(base: url)))
    }
}

private struct CheckResult: View {
    let result: HubClient.Check

    var body: some View {
        Label {
            Text(message)
                .foregroundStyle(result == .ok ? .primary : .secondary)
        } icon: {
            Image(systemName: result == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result == .ok ? .green : .orange)
        }
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        switch result {
        case .ok:
            "Connected to your hub."
        case .notAHub:
            "Something answered at this address, but it isn't a Quill hub. Check the address and port."
        case .httpError(let status):
            "The hub answered with an error (HTTP \(status)). Check that Quill is running on the hub Mac."
        case .unreachable:
            "Can't reach this address. Check that Tailscale is connected on this iPhone and that the hub Mac is awake."
        }
    }
}
