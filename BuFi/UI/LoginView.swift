import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field {
        case server
        case username
        case password
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
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(BuFiTheme.accentSoft)
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
                            if session.phase == .connecting {
                                ProgressView().tint(.white)
                            }
                            Text(
                                session.phase == .connecting
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
                    .disabled(
                        server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        password.isEmpty ||
                        session.phase == .connecting
                    )
                    .buttonStyle(BuFiPressStyle())
                    .padding(.top, 22)

                    Text("비밀번호는 Apple Keychain에만 저장됩니다.")
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
                    focus = field == .server ? .username : .password
                }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(
            BuFiTheme.elevated,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    private func connect() {
        focus = nil
        Task {
            await model.login(serverURL: server, username: username, password: password)
        }
    }
}
