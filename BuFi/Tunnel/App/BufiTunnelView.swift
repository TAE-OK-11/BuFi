import CryptoKit
import NetworkExtension
import SwiftUI
import UniformTypeIdentifiers

struct BufiTunnelView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var editingProfile: TunnelProfile?
    @State private var isCreating = false
    @State private var isImporting = false
    @State private var deleteCandidate: TunnelProfile?
    @State private var dnsProfile: TunnelProfile?
    @State private var protectionProfile: TunnelProfile?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                serverConnectionSection
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
        .sheet(item: $dnsProfile) { profile in
            NavigationStack { TunnelDNSSettingsEditor(profile: profile) }
        }
        .sheet(item: $protectionProfile) { profile in
            NavigationStack { TunnelAdBlockingEditor(profile: profile) }
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

    private var serverConnectionSection: some View {
        tunnelSection("OpenSubsonic server") {
            NavigationLink {
                TunnelServerRoutingView()
                    .environmentObject(model)
                    .environmentObject(session)
            } label: {
                HStack(spacing: 13) {
                    Circle()
                        .fill(BuFiTheme.accent.opacity(0.14))
                        .frame(width: 46, height: 46)
                        .overlay {
                            Image(systemName: "server.rack")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(BuFiTheme.accent)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: session.connectedServerAddress.isEmpty
                             ? String(localized: "Connected server")
                             : session.connectedServerAddress)
                            .font(.system(size: 16, weight: .bold))
                            .lineLimit(2)
                        Text(session.activeServerUsesTunnel
                             ? String(localized: "Using tunnel server address")
                             : String(localized: "Using default server address"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(
                                session.activeServerUsesTunnel
                                    ? Color.green
                                    : Color.secondary
                            )
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                        "The profile and private key are saved securely in the app, but Bufi App Group Keychain access is unavailable. Packet Tunnel will not be started.",
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
                diagnosticRow(
                    "Ad blocking",
                    value: tunnel.diagnostics.dnsProtectionEnabled
                        ? (tunnel.diagnostics.dnsProtectionPreset?.title ?? String(localized: "On"))
                        : String(localized: "Off")
                )
                if tunnel.diagnostics.dnsProtectionEnabled {
                    diagnosticRow(
                        "Blocked DNS queries",
                        value: "\(tunnel.diagnostics.dnsBlockedQueryCount ?? 0)"
                    )
                }
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
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
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
            Button { dnsProfile = tunnel.selectedProfile } label: {
                Label("DNS settings", systemImage: "network.badge.shield.half.filled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(tunnel.selectedProfile == nil)
            Button { protectionProfile = tunnel.selectedProfile } label: {
                Label("Ad blocking", systemImage: "shield.lefthalf.filled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(tunnel.selectedProfile == nil)
            Button { editingProfile = tunnel.selectedProfile } label: {
                Label("Edit selected", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(tunnel.selectedProfile == nil)
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

private struct TunnelServerRoutingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState
    @Environment(\.dismiss) private var dismiss
    @State private var primaryURL = ""
    @State private var alternateURLs: [String] = []
    @State private var tunnelURL = ""
    @State private var isSaving = false

    var body: some View {
        Form {
            Section("Current connection") {
                LabeledContent(
                    "Address",
                    value: session.connectedServerAddress.isEmpty
                        ? String(localized: "Unknown")
                        : session.connectedServerAddress
                )
                LabeledContent(
                    "Route",
                    value: session.activeServerUsesTunnel
                        ? String(localized: "Bufi Tunnel")
                        : String(localized: "Default network")
                )
            }

            Section {
                TextField("Primary server URL", text: $primaryURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } footer: {
                Text("This address is used whenever Bufi Tunnel is disconnected.")
            }

            Section("Other server addresses") {
                ForEach(Array(alternateURLs.indices), id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField("Additional IP or URL", text: $alternateURLs[index])
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button {
                            let oldPrimary = primaryURL
                            primaryURL = alternateURLs[index]
                            alternateURLs[index] = oldPrimary
                        } label: {
                            Image(systemName: "arrow.up.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use as primary server")
                        Button(role: .destructive) {
                            alternateURLs.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove server address")
                    }
                }
                Button("Add server address", systemImage: "plus.circle") {
                    alternateURLs.append("")
                }
            }

            Section {
                TextField("Tunnel server URL (optional)", text: $tunnelURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } footer: {
                Text("When Bufi Tunnel connects, Bufi verifies this address and switches OpenSubsonic traffic to it automatically. Disconnecting restores the primary address.")
            }
        }
        .navigationTitle("Server addresses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(isSaving || primaryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task { load() }
    }

    private func load() {
        guard primaryURL.isEmpty,
              let configuration = session.serverEndpointConfiguration else { return }
        primaryURL = configuration.primaryURL
        alternateURLs = configuration.alternateURLs
        tunnelURL = configuration.tunnelURL ?? ""
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let saved = await model.saveServerEndpointConfiguration(
            OpenSubsonicEndpointConfiguration(
                primaryURL: primaryURL,
                alternateURLs: alternateURLs,
                tunnelURL: tunnelURL
            )
        )
        if saved { dismiss() }
    }
}

private struct TunnelDNSSettingsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var profile: TunnelProfile
    @State private var dns: TunnelDNSConfiguration
    @State private var localError: String?

    init(profile: TunnelProfile) {
        _profile = State(initialValue: profile)
        _dns = State(initialValue: profile.dns)
    }

    var body: some View {
        Form {
            Section("DNS resolver") {
                Picker("Resolver", selection: $dns.mode) {
                    ForEach(TunnelDNSMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            if dns.mode != .system {
                Section("Resolver configuration") {
                    if dns.mode == .plain || dns.mode == .https {
                        TextField(
                            "Server IPs / bootstrap IPs",
                            text: Binding(
                                get: { dns.servers.joined(separator: ", ") },
                                set: { dns.servers = split($0) }
                            ),
                            axis: .vertical
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    if dns.mode == .https {
                        TextField("https://dns.example/dns-query", text: $dns.resolverEndpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } else if dns.mode == .tls || dns.mode == .quic {
                        TextField("Resolver host or IP", text: $dns.resolverEndpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("TLS server name (optional)", text: $dns.serverName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", text: Binding(
                            get: { String(dns.port) },
                            set: { dns.port = UInt16($0) ?? dns.port }
                        ))
                        .keyboardType(.numberPad)
                    }
                }
            }

            Section {
                switch dns.mode {
                case .system:
                    Text("Use the system resolver without overriding tunnel DNS.")
                case .plain:
                    Text("Enter one or more IPv4 or IPv6 DNS server addresses. Plain DNS uses port 53.")
                case .https:
                    Text("Enter an HTTPS dns-query endpoint and optional bootstrap IP addresses.")
                case .tls:
                    Text("DNS-over-TLS uses port 853 by default.")
                case .quic:
                    Text("DNS-over-QUIC uses port 853 by default through the isolated DoQ proxy.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("DNS settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(tunnel.isBusy)
            }
        }
        .alert("Invalid profile", isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button("OK") { localError = nil }
        } message: {
            Text(localError ?? String(localized: "Unknown error"))
        }
        .onChange(of: dns.mode) { _, mode in
            if mode == .plain { dns.port = 53 }
            if mode == .tls || mode == .quic { dns.port = 853 }
        }
    }

    private func save() async {
        do {
            try TunnelProfileValidator.validateDNS(dns)
            profile.dns = dns
            if await tunnel.save(profile: profile, privateKey: nil, presharedKeys: [:]) {
                dismiss()
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private func split(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct TunnelAdBlockingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var profile: TunnelProfile
    @State private var protection: TunnelDNSProtectionConfiguration
    @State private var blockedRules: String
    @State private var allowedRules: String
    @State private var localError: String?

    init(profile: TunnelProfile) {
        _profile = State(initialValue: profile)
        _protection = State(initialValue: profile.dns.effectiveProtection)
        _blockedRules = State(initialValue: profile.dns.effectiveProtection.blockedDomains.joined(separator: "\n"))
        _allowedRules = State(initialValue: profile.dns.effectiveProtection.allowedDomains.joined(separator: "\n"))
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Circle()
                        .fill(BuFiTheme.accent.opacity(0.14))
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(BuFiTheme.accent)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DNS ad blocking")
                            .font(.headline)
                        Text(
                            protection.isEnabled
                                ? String(localized: "Protection is active")
                                : String(localized: "Protection is off")
                        )
                            .font(.subheadline)
                            .foregroundStyle(protection.isEnabled ? Color.green : Color.secondary)
                    }
                }
                Toggle("Block ads, trackers, and threats", isOn: $protection.isEnabled)
                    .tint(BuFiTheme.accent)
            }

            if protection.isEnabled {
                Section("Protection level") {
                    Picker("Mode", selection: $protection.preset) {
                        ForEach(TunnelDNSProtectionPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(protection.preset.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Lightweight design") {
                    if hasParsedCustomRules {
                        Label("Custom rules use an encrypted local DNS boundary", systemImage: "lock.shield")
                    } else {
                        Label("Uses Apple native DNS-over-HTTPS", systemImage: "lock.shield")
                    }
                    Label("No downloaded blocklist or background update timer", systemImage: "leaf")
                    Label("Bufi does not store DNS query history", systemImage: "eye.slash")
                    LabeledContent("Resolver", value: protection.preset.resolver.resolverEndpoint)
                        .font(.caption)
                }

                Section("Custom filters") {
                    TextField("Blocked domains", text: $blockedRules, axis: .vertical)
                        .lineLimit(3...8)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Allowed domains", text: $allowedRules, axis: .vertical)
                        .lineLimit(2...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Custom block rules", value: "\(parsedBlockedRules.count)")
                    LabeledContent("Custom allow rules", value: "\(parsedAllowedRules.count)")
                } footer: {
                    Text("Add one domain per line. Comma-separated domains, hosts entries, and basic ||domain.example^ rules are also accepted. Allowed domains override only your custom blocked parent domains.")
                }
            }

            Section {
                LabeledContent("Saved custom DNS", value: profile.dns.mode.title)
            } footer: {
                Text("Your current DNS settings are preserved and automatically restored when ad blocking is turned off. Reconnect an active tunnel to apply changes.")
            }

            Section {
                Link(
                    "Open-source DNS engine reference",
                    destination: URL(string: "https://github.com/AdguardTeam/DnsLibs")!
                )
                Link(
                    "Public resolver documentation",
                    destination: URL(string: "https://adguard-dns.io/en/public-dns.html")!
                )
            } footer: {
                Text("Bufi uses the documented public resolver through iOS APIs. It does not embed the larger AdGuard C++ engine.")
            }
        }
        .navigationTitle("Ad blocking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(tunnel.isBusy)
            }
        }
        .alert("Invalid profile", isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button("OK") { localError = nil }
        } message: {
            Text(localError ?? String(localized: "Unknown error"))
        }
    }

    private func save() async {
        protection.blockedDomains = parsedBlockedRules
        protection.allowedDomains = parsedAllowedRules
        profile.dns.protection = protection
        do {
            try TunnelProfileValidator.validateDNS(profile.dns)
            if await tunnel.save(profile: profile, privateKey: nil, presharedKeys: [:]) {
                dismiss()
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private var parsedBlockedRules: [String] {
        TunnelDNSRuleParser.parse(blockedRules)
    }

    private var parsedAllowedRules: [String] {
        TunnelDNSRuleParser.parse(allowedRules)
    }

    private var hasParsedCustomRules: Bool {
        !parsedBlockedRules.isEmpty || !parsedAllowedRules.isEmpty
    }
}
