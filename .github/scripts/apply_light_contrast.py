from pathlib import Path


def replace_if_present(text: str, old: str, new: str) -> str:
    return text.replace(old, new, 1) if old in text else text


detail = Path("BuFi/UI/MusicDetailView.swift")
text = detail.read_text()
if "@Environment(\\.colorScheme) private var colorScheme" not in text:
    text = text.replace(
        "    @EnvironmentObject private var audio: AudioEngine\n",
        "    @EnvironmentObject private var audio: AudioEngine\n"
        "    @Environment(\\.colorScheme) private var colorScheme\n",
        1,
    )
text = replace_if_present(
    text,
    "            .shadow(color: .black.opacity(0.22), radius: 20, y: 10)\n",
    """            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.22 : 0.13),
                radius: 20,
                y: 10
            )
""",
)
text = replace_if_present(
    text,
    "            .shadow(color: .black.opacity(0.34), radius: 24, y: 14)\n",
    """            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.34 : 0.18),
                radius: 24,
                y: 14
            )
""",
)

collection_start = text.index("    private var collectionHero: some View {")
collection_end = text.index("    private var controls: some View {", collection_start)
collection = text[collection_start:collection_end]
collection = replace_if_present(
    collection,
    "                    .foregroundStyle(.white)\n",
    "                    .foregroundStyle(collectionTitleColor)\n",
)
collection = replace_if_present(
    collection,
    "                        .foregroundStyle(.white.opacity(0.72))\n",
    "                        .foregroundStyle(collectionSubtitleColor)\n",
)
text = text[:collection_start] + collection + text[collection_end:]

controls_start = text.index("    private var controls: some View {")
controls_end = text.index("    private var artistAbout: some View {", controls_start)
new_controls = '''    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if canFavorite {
                    Button(action: toggleFavorite) {
                        secondaryControl(
                            Image(systemName: isFavorite ? "checkmark" : "plus")
                                .font(.system(size: 19, weight: .semibold)),
                            diameter: 42
                        )
                    }
                    .buttonStyle(BuFiPressStyle())
                    .accessibilityLabel(isFavorite ? "라이브러리에서 제거" : "라이브러리에 추가")
                }

                Button { downloadAll() } label: {
                    secondaryControl(
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 19, weight: .semibold)),
                        diameter: 42
                    )
                }
                .buttonStyle(BuFiPressStyle())
                .disabled(songs.isEmpty)
                .accessibilityLabel("모두 오프라인 저장")

                Menu {
                    Button {
                        if let first = songs.first { audio.play(first, in: songs) }
                    } label: {
                        Label("모두 재생", systemImage: "play.fill")
                    }
                    Button {
                        guard !songs.isEmpty else { return }
                        let shuffled = songs.shuffled()
                        if let first = shuffled.first { audio.play(first, in: shuffled) }
                    } label: {
                        Label("셔플 재생", systemImage: "shuffle")
                    }
                    Button { downloadAll() } label: {
                        Label("모두 오프라인 저장", systemImage: "arrow.down.circle")
                    }
                } label: {
                    secondaryControl(
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .semibold)),
                        diameter: 42
                    )
                }
                .buttonStyle(BuFiPressStyle())
                .accessibilityLabel("더 보기")
            }

            Spacer(minLength: 12)

            Button {
                guard !songs.isEmpty else { return }
                let shuffled = songs.shuffled()
                if let first = shuffled.first { audio.play(first, in: shuffled) }
            } label: {
                secondaryControl(
                    Image(systemName: "shuffle")
                        .font(.system(size: 21, weight: .semibold)),
                    diameter: 52
                )
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(songs.isEmpty)
            .accessibilityLabel("셔플 재생")

            Button {
                if let first = songs.first { audio.play(first, in: songs) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(BuFiTheme.accent, in: Circle())
                    .overlay {
                        Circle().stroke(
                            .white.opacity(colorScheme == .dark ? 0.10 : 0.28),
                            lineWidth: 0.8
                        )
                    }
                    .shadow(color: BuFiTheme.accent.opacity(0.24), radius: 14, y: 7)
                    .offset(x: 1)
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(songs.isEmpty)
            .accessibilityLabel("모두 재생")
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 22)
    }

'''
text = text[:controls_start] + new_controls + text[controls_end:]

text = replace_if_present(
    text,
    """        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(BuFiTheme.separator.opacity(0.38), lineWidth: 0.6)
        }
        .padding(.horizontal, 16)
""",
    """        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(contrastSeparator, lineWidth: 0.8)
        }
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.08 : 0.035),
            radius: 12,
            y: 5
        )
        .padding(.horizontal, 16)
""",
)

background_start = text.index("    private var background: some View {")
background_end = text.index("    private var isArtist: Bool {", background_start)
new_helpers = '''    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(palette.top).opacity(colorScheme == .dark ? 0.92 : 0.34),
                    BuFiTheme.background
                ],
                startPoint: .top,
                endPoint: .init(x: 0.5, y: 0.43)
            )
            if colorScheme == .light {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.16),
                        Color.white.opacity(0.70),
                        BuFiTheme.background
                    ],
                    startPoint: .top,
                    endPoint: .init(x: 0.5, y: 0.52)
                )
            }
        }
        .ignoresSafeArea()
    }

    private func secondaryControl<Content: View>(
        _ content: Content,
        diameter: CGFloat
    ) -> some View {
        content
            .foregroundStyle(detailControlForeground)
            .frame(width: diameter, height: diameter)
            .background(detailControlFill, in: Circle())
            .overlay {
                Circle().stroke(
                    detailControlStroke,
                    lineWidth: colorScheme == .dark ? 0.7 : 1.0
                )
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.12 : 0.045),
                radius: 8,
                y: 4
            )
            .buFiGlass(cornerRadius: diameter / 2, interactive: true)
    }

    private var detailControlForeground: Color {
        colorScheme == .dark ? .white.opacity(0.92) : .black.opacity(0.78)
    }

    private var detailControlFill: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.065)
    }

    private var detailControlStroke: Color {
        colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.16)
    }

    private var collectionTitleColor: Color {
        colorScheme == .dark ? .white : .primary
    }

    private var collectionSubtitleColor: Color {
        colorScheme == .dark ? .white.opacity(0.72) : .secondary
    }

    private var contrastSeparator: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.12)
    }

'''
text = text[:background_start] + new_helpers + text[background_end:]
detail.write_text(text)

settings = Path("BuFi/UI/SettingsView.swift")
text = settings.read_text()
if ".pickerStyle(.segmented)\n                    .tint(BuFiTheme.accent)" not in text:
    text = text.replace(
        "                    .pickerStyle(.segmented)\n",
        "                    .pickerStyle(.segmented)\n                    .tint(BuFiTheme.accent)\n",
        1,
    )
if ".scrollContentBackground(.hidden)" not in text:
    text = text.replace(
        "            .listStyle(.insetGrouped)\n            .navigationTitle(\"설정\")\n",
        "            .listStyle(.insetGrouped)\n"
        "            .scrollContentBackground(.hidden)\n"
        "            .background(BuFiScreenBackground())\n"
        "            .navigationTitle(\"설정\")\n",
        1,
    )
settings.write_text(text)

print("light mode contrast patch applied")
