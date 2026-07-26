import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel

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
                colors: [Color(red: 0.16, green: 0.19, blue: 0.18), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.green)
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
                            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                    }
                    .padding(.top, 34)

                    if let error = model.errorMessage {
                        Text(error)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.top, 12)
                    }

                    Button(action: connect) {
                        HStack {
                            if model.sessionState == .connecting {
                                ProgressView().tint(.black)
                            }
                            Text(model.sessionState == .connecting ? "연결 중…" : "서버에 연결")
                        }
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(.green, in: Capsule())
                    }
                    .disabled(
                        server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        password.isEmpty ||
                        model.sessionState == .connecting
                    )
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
            TextField(title, text: text)
                .textContentType(contentType)
                .focused($focus, equals: field)
                .submitLabel(field == .server ? .next : field == .username ? .next : .go)
                .onSubmit {
                    switch field {
                    case .server: focus = .username
                    case .username: focus = .password
                    case .password: connect()
                    }
                }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
    }

    private func connect() {
        focus = nil
        Task {
            await model.login(serverURL: server, username: username, password: password)
        }
    }
}

