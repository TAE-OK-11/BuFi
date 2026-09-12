import CryptoKit
import NetworkExtension
import SwiftUI
import UniformTypeIdentifiers

struct BufiTunnelView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var editingProfile: TunnelProfile?
    @State private var isCreating = false
    @State private var isImporting = false
    @State private var deleteCandidate: TunnelProfile?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                statusSection
                profilesSection
                actionsSection
                diagnosticsSection
            }
            .padding(16)
            .buFiMiniPlayerContentClearance(idle: 56, playing: 180)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(BuFiScreenBackground())
        .navigationTitle("Bufi Tunnel")
        .navigationBarTitleDisplayMode(.inline)
        .task { await tunnel.bootstrap() }
        .sheet(isPresented: $isCreating) {
            NavigationStack { TunnelProfileEditor(existing: nil) }
        }
        .sheet(item: $editingProfile) { profile in
            NavigationStack { TunnelProfileEditor(existing: profile) }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "conf") ?? .plainText, .plainText]
        ) { result in
            Task { await importFile(result) }
        }
        .confirmationDialog(
            "Delete this tunnel profile?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let profile = deleteCandidate { Task { await tunnel.delete(profile) } }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("The profile metadata and its private and preshared keys will be removed.")
        }
        .alert(
            "Bufi Tunnel",
            isPresented: Binding(
                get: { tunnel.errorMessage != nil },
                set: { if !$0 { tunnel.errorMessage = nil } }
            )
        ) {
            Button("OK") { tunnel.errorMessage = nil }
        } message: {
            Text(tunnel.errorMessage ?? "Unknown error")
        }
    }

    private var statusSection: some View {
        tunnelSection("Connection") {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(statusColor.opacity(0.16))
                        .frame(width: 46, height: 46)
                        .overlay {
                            Image(systemName: statusIcon)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(statusColor)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tunnel.selectedProfile?.name ?? String(localized: "No profile"))
                            .font(.system(size: 17, weight: .bold))
                        Text(statusTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }
                    Spacer()
                    if tunnel.isBusy { ProgressView().controlSize(.small) }
                }
                Toggle("Enable tunnel profile", isOn: Binding(
                    get: { tunnel.isEnabled },
                    set: { enabled in Task { await tunnel.setEnabled(enabled) } }
                ))
                .disabled(
                    tunnel.selectedProfile == nil
                        || tunnel.selectedProfileRequiresSupportedSigning
                        || tunnel.isBusy
                )

                if tunnel.selectedProfileRequiresSupportedSigning {
                    Label(
                        "The profile and private key are saved securely in the app, but the shared Tunnel Keychain entitlement is unavailable. Packet Tunnel will not be started.",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    if isActive { tunnel.disconnect() } else { Task { await tunnel.connect() } }
                } label: {
                    Label {
                        Text(connectionActionTitle)
                    } icon: {
                        Image(systemName: isActive ? "stop.fill" : "bolt.fill")
                    }
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(isActive ? .red : BuFiTheme.accent)
                .disabled(tunnel.selectedProfile == nil || (!isActive && !tunnel.canConnect) || tunnel.isBusy)
            }
        }
    }

    private var profilesSection: some View {
        tunnelSection("Profiles") {
            VStack(spacing: 0) {
                if tunnel.profiles.isEmpty {
                    Text("Create or import a standard WireGuard configuration to begin.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(tunnel.profiles) { profile in
                    if profile.id != tunnel.profiles.first?.id { Divider().padding(.vertical, 10) }
                    HStack(spacing: 10) {
                        Button { tunnel.select(profile) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tunnel.selectedProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(tunnel.selectedProfileID == profile.id ? BuFiTheme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).font(.system(size: 15, weight: .semibold))
                                    Text(profile.isFullTunnel
                                         ? String(localized: "Full tunnel")
                                         : String(localized: "Split tunnel"))
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button("Edit", systemImage: "pencil") { editingProfile = profile }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleteCandidate = profile }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.system(size: 20))
                        }
                    }
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        tunnelSection("Diagnostics") {
            VStack(spacing: 11) {
                diagnosticRow("Latest handshake", value: tunnel.diagnostics.latestHandshake?.formatted(date: .abbreviated, time: .standard) ?? String(localized: "Never"))
                Divider()
                diagnosticRow("Received", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: tunnel.diagnostics.rxBytes), countStyle: .binary))
                diagnosticRow("Transmitted", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: tunnel.diagnostics.txBytes), countStyle: .binary))
                Divider()
                diagnosticRow("Endpoint", value: tunnel.diagnostics.currentEndpoint ?? "—")
                diagnosticRow("Network", value: tunnel.diagnostics.currentNetworkPath)
                diagnosticRow("Reconnects", value: "\(tunnel.diagnostics.reconnectCount)")
                diagnosticRow("DNS", value: tunnel.diagnostics.dnsMode.title)
                if let endpoint = tunnel.diagnostics.dnsResolverEndpoint {
                    diagnosticRow("DNS endpoint", value: endpoint)
                }
                if let error = tunnel.diagnostics.latestError {
                    Divider()
                    Text(error)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button { isCreating = true } label: {
                Label("Add manually", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { isImporting = true } label: {
                Label("Import .conf", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func tunnelSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 20, weight: .bold))
            BuFiGroupedSurface { content().padding(16) }
        }
    }

    private func diagnosticRow(_ name: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing).lineLimit(3)
        }
        .font(.system(size: 13.5))
    }

    private var isActive: Bool {
        [.connecting, .connected, .reasserting, .disconnecting].contains(tunnel.status)
    }

    private var statusTitle: LocalizedStringKey {
        if tunnel.selectedProfileRequiresSupportedSigning { return "Signing required" }
        switch tunnel.status {
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        @unknown default: return "Unknown"
        }
    }

    private var statusColor: Color {
        if tunnel.selectedProfileRequiresSupportedSigning { return .orange }
        switch tunnel.status {
        case .connected: return .green
        case .connecting, .reasserting: return .orange
        case .disconnecting: return .orange
        default: return .secondary
        }
    }

    private var statusIcon: String {
        if tunnel.selectedProfileRequiresSupportedSigning { return "exclamationmark.shield.fill" }
        return tunnel.status == .connected ? "lock.fill" : "network"
    }

    private var connectionActionTitle: LocalizedStringKey {
        isActive ? "Disconnect" : "Connect"
    }

    private func importFile(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingPathExtension().lastPathComponent
            _ = await tunnel.importConfiguration(text: text, name: name)
        } catch {
            tunnel.errorMessage = error.localizedDescription
        }
    }
}

private struct TunnelProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var profile: TunnelProfile
    @State private var pendingPrivateKey: Data?
    @State private var presharedKeys: [UUID: String] = [:]
    @State private var localError: String?
    private let isNew: Bool

    init(existing: TunnelProfile?) {
        isNew = existing == nil
        if let existing {
            _profile = State(initialValue: existing)
            _pendingPrivateKey = State(initialValue: nil)
        } else {
            let pair = TunnelKeyPair.generate()
            _profile = State(initialValue: TunnelProfile(
                name: "",
                privateKeyReference: "private-\(UUID().uuidString)",
                publicKey: pair.publicKey,
                addresses: [],
                peers: [TunnelPeer()],
                mtu: nil,
                dns: .system
            ))
            _pendingPrivateKey = State(initialValue: pair.privateKey)
        }
    }

    var body: some View {
        Form {
            Section("Interface") {
                TextField("Profile name", text: $profile.name)
                multilineField("Client addresses (comma separated)", values: $profile.addresses)
                TextField("MTU (automatic: 1280)", text: Binding(
                    get: { profile.mtu.map(String.init) ?? "" },
                    set: { profile.mtu = UInt16($0) }
                ))
                .keyboardType(.numberPad)
                LabeledContent("Public key") {
                    Button(abbreviate(profile.publicKey)) {
                        UIPasteboard.general.string = profile.publicKey
                    }
                    .font(.system(.caption, design: .monospaced))
                }
                Button("Generate new keypair", systemImage: "key.fill") {
                    let pair = TunnelKeyPair.generate()
                    pendingPrivateKey = pair.privateKey
                    profile.publicKey = pair.publicKey
                }
                Text("The private key is hidden and stored only in the device Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(Array(profile.peers.indices), id: \.self) { index in
                peerSection(index: index)
            }

            Section {
                Button("Add peer", systemImage: "plus.circle") {
                    profile.peers.append(TunnelPeer())
                }
            }

            Section("DNS") {
                Picker("Resolver", selection: $profile.dns.mode) {
                    ForEach(TunnelDNSMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                if profile.dns.mode != .system {
                    multilineField("Server IPs / bootstrap IPs", values: $profile.dns.servers)
                }
                if profile.dns.mode == .https {
                    TextField("https://dns.example/dns-query", text: $profile.dns.resolverEndpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else if profile.dns.mode == .tls || profile.dns.mode == .quic {
                    TextField("Resolver host or IP", text: $profile.dns.resolverEndpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("TLS server name (optional)", text: $profile.dns.serverName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: Binding(
                        get: { String(profile.dns.port) },
                        set: { profile.dns.port = UInt16($0) ?? profile.dns.port }
                    )).keyboardType(.numberPad)
                }
            }
        }
        .navigationTitle(isNew ? String(localized: "New tunnel") : String(localized: "Edit tunnel"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(tunnel.isBusy)
            }
        }
        .alert("Invalid profile", isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button("OK") { localError = nil }
        } message: { Text(localError ?? "Unknown error") }
        .onChange(of: profile.dns.mode) { _, mode in
            if mode == .plain { profile.dns.port = 53 }
            if mode == .tls || mode == .quic { profile.dns.port = 853 }
        }
    }

    @ViewBuilder
    private func peerSection(index: Int) -> some View {
        let id = profile.peers[index].id
        Section(String(format: String(localized: "Peer %d"), locale: .current, index + 1)) {
            TextField("Public key", text: $profile.peers[index].publicKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(
                profile.peers[index].presharedKeyReference == nil
                    ? String(localized: "Preshared key (optional)")
                    : String(localized: "Replace saved preshared key"),
                text: Binding(get: { presharedKeys[id] ?? "" }, set: { presharedKeys[id] = $0 })
            )
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Generate preshared key") {
                let key = SymmetricKey(size: .bits256)
                presharedKeys[id] = key.withUnsafeBytes { Data($0).base64EncodedString() }
            }
            HStack {
                TextField("Endpoint host", text: $profile.peers[index].endpointHost)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: Binding(
                    get: { String(profile.peers[index].endpointPort) },
                    set: { profile.peers[index].endpointPort = UInt16($0) ?? profile.peers[index].endpointPort }
                )).keyboardType(.numberPad).frame(width: 82)
            }
            multilineField("AllowedIPs (comma separated)", values: $profile.peers[index].allowedIPs)
            TextField("PersistentKeepalive seconds", text: Binding(
                get: { profile.peers[index].persistentKeepalive.map(String.init) ?? "" },
                set: { profile.peers[index].persistentKeepalive = UInt16($0) }
            )).keyboardType(.numberPad)
            if profile.peers.count > 1 {
                Button("Remove peer", role: .destructive) { profile.peers.remove(at: index) }
            }
        }
    }

    private func multilineField(_ title: LocalizedStringKey, values: Binding<[String]>) -> some View {
        TextField(title, text: Binding(
            get: { values.wrappedValue.joined(separator: ", ") },
            set: { values.wrappedValue = split($0) }
        ), axis: .vertical)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func save() async {
        do {
            var secrets: [UUID: Data] = [:]
            for (id, value) in presharedKeys where !value.isEmpty {
                guard let data = Data(base64Encoded: value), data.count == 32 else {
                    throw TunnelKeychainError.invalidSecret
                }
                secrets[id] = data
            }
            if await tunnel.save(profile: profile, privateKey: pendingPrivateKey, presharedKeys: secrets) {
                dismiss()
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private func split(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func abbreviate(_ value: String) -> String {
        guard value.count > 18 else { return value }
        return "\(value.prefix(8))…\(value.suffix(8))"
    }
}
