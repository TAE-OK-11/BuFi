import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var authMethod: ServerAuthMethod = .password
    @State private var serverSupportsAPIKey = false
    @State private var discoveredExtensions: OpenSubsonicExtensionRegistry?
    @State private var isSubmitting = false
    @State private var loginTask: Task<Void, Never>?
    @State private var extensionDiscoveryTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field {
        case server
        case username
        case password
        case apiKey
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    BuFiTheme.accent.opacity(0.30),
                    BuFiTheme.deezerGlow.opacity(0.12),
                    BuFiTheme.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Bufi")
                        .font(.custom("Unbounded_800wght", fixedSize: 34))
                        .tracking(-2.2)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, BuFiTheme.accentSoft],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .buFiGlass(cornerRadius: 20)
                        .accessibilityLabel("Bufi")
                        .padding(.top, 24)

                    Spacer(minLength: 72)

                    Text("내 음악은\n내 서버에.")
                        .font(.system(size: 45, weight: .black))
                        .tracking(-1.7)
                        .lineSpacing(-2)
                    Text("Navidrome과 OpenSubsonic 서버를 iPhone에서 빠르고 자연스럽게 스트리밍하세요.")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .padding(.top, 18)

                    VStack(spacing: 14) {
                        input(
                            "서버 주소",
                            text: $server,
                            icon: "server.rack",
                            field: .server,
                            contentType: .URL
                        )
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onChange(of: server) { _, _ in
                            refreshServerCapabilities()
                        }

                        if let serverHint {
                            Text(serverHint)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        Picker("인증 방식", selection: $authMethod) {
                            Text("사용자 이름 + 비밀번호").tag(ServerAuthMethod.password)
                            Text("API 키").tag(ServerAuthMethod.apiKey)
                        }
                        .pickerStyle(.segmented)

                        if serverSupportsAPIKey {
                            Text("이 서버는 OpenSubsonic API 키 인증을 지원합니다.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(BuFiTheme.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        if authMethod == .password {
                            input(
                                "사용자 이름",
                                text: $username,
                                icon: "person.fill",
                                field: .username,
                                contentType: .username
                            )
                            .textInputAutocapitalization(.never)

                            SecureField("비밀번호", text: $password)
                                .textContentType(.password)
                                .focused($focus, equals: .password)
                                .submitLabel(.go)
                                .onSubmit(connect)
                                .padding(.horizontal, 16)
                                .frame(height: 56)
                                .background(
                                    BuFiTheme.elevated,
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                                )
                        } else {
                            SecureField("API 키", text: $password)
                                .textContentType(.password)
                                .focused($focus, equals: .apiKey)
                                .submitLabel(.go)
                                .onSubmit(connect)
                                .padding(.horizontal, 16)
                                .frame(height: 56)
                                .background(
                                    BuFiTheme.elevated,
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                                )
                        }
                    }
                    .padding(.top, 34)

                    if let error = session.errorMessage {
                        Text(error)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.top, 12)
                    }

                    Button(action: connect) {
                        HStack {
                            if isSubmitting || session.phase == .connecting {
                                ProgressView().tint(.white)
                            }
                            Text(
                                isSubmitting || session.phase == .connecting
                                    ? String(localized: "연결 중…")
                                    : String(localized: "서버에 연결")
                            )
                        }
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(BuFiTheme.accent, in: Capsule())
                    }
                    .disabled(!canSubmit)
                    .buttonStyle(BuFiPressStyle())
                    .padding(.top, 22)

                    Text(
                        authMethod == .apiKey
                            ? String(localized: "API 키는 Apple Keychain에만 저장됩니다.")
                            : String(localized: "비밀번호는 Apple Keychain에만 저장됩니다.")
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                }
                .padding(.horizontal, 24)
                .frame(minHeight: UIScreen.main.bounds.height - 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private func input(
        _ title: String,
        text: Binding<String>,
        icon: String,
        field: Field,
        contentType: UITextContentType
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            TextField(LocalizedStringKey(title), text: text)
                .textContentType(contentType)
                .focused($focus, equals: field)
                .submitLabel(.next)
                .onSubmit {
                    switch field {
                    case .server:
                        focus = authMethod == .password ? .username : .apiKey
                    case .username:
                        focus = .password
                    case .password, .apiKey:
                        break
                    }
                }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(
            BuFiTheme.elevated,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    private var canSubmit: Bool {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasIdentity = authMethod == .apiKey || !trimmedUsername.isEmpty
        if case .success = ServerURLNormalization.normalize(server),
           hasIdentity,
           !password.isEmpty,
           !isSubmitting,
           session.phase != .connecting {
            return true
        }
        return false
    }

    private var serverHint: String? {
        switch ServerURLNormalization.normalize(server) {
        case .success(let url):
            let persisted = ServerURLNormalization.persistedServerURL(from: url)
            let typed = server.trimmingCharacters(in: .whitespacesAndNewlines)
            guard persisted.caseInsensitiveCompare(typed) != .orderedSame else {
                return nil
            }
            return String(
                format: String(localized: "연결 주소: %@"),
                persisted
            )
        case .empty:
            return nil
        case .insecure:
            return OpenSubsonicError.insecureServerURL.localizedDescription
        case .credentialsInURL:
            return OpenSubsonicError.credentialsEmbeddedInServerURL.localizedDescription
        case .invalid:
            return nil
        }
    }

    private func refreshServerCapabilities() {
        extensionDiscoveryTask?.cancel()
        serverSupportsAPIKey = false
        discoveredExtensions = nil
        guard case .success(let url) = ServerURLNormalization.normalize(server) else {
            return
        }
        let persisted = ServerURLNormalization.persistedServerURL(from: url)
        extensionDiscoveryTask = Task {
            guard let registry = await OpenSubsonicPublicDiscovery.fetchExtensions(
                serverURL: persisted
            ) else {
                return
            }
            guard !Task.isCancelled else { return }
            discoveredExtensions = registry
            serverSupportsAPIKey = registry.supports(
                OpenSubsonicExtensionName.apiKeyAuthentication
            )
        }
    }

    private func connect() {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = ServerURLNormalization.normalize(server)
        guard !isSubmitting,
              session.phase != .connecting,
              !password.isEmpty else { return }
        if authMethod == .password, trimmedUsername.isEmpty { return }
        guard case .success(let url) = outcome else {
            session.errorMessage = serverHint
                ?? OpenSubsonicError.invalidServerURL.localizedDescription
            return
        }

        focus = nil
        isSubmitting = true
        session.errorMessage = nil
        let submittedPassword = password
        let submittedAuthMethod = authMethod
        loginTask = Task {
            await model.login(
                serverURL: ServerURLNormalization.persistedServerURL(from: url),
                username: trimmedUsername,
                password: submittedPassword,
                authMethod: submittedAuthMethod,
                discoveredExtensions: discoveredExtensions
            )
            isSubmitting = false
            loginTask = nil
        }
    }
}
