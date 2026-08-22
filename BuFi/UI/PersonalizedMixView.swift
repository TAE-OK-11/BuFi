import SwiftUI

struct PersonalizedMixArtwork: View {
    let mix: PersonalizedMix
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if mix.kind == .artist, let coverArt = mix.artworkCoverArt {
                ArtworkView(
                    coverArt: coverArt,
                    size: size,
                    cornerRadius: 0
                )
                .frame(width: size, height: size)

                LinearGradient(
                    colors: [
                        .black.opacity(0.08),
                        .clear,
                        .black.opacity(0.78)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                SmartMixCoverBackground(
                    theme: coverTheme,
                    size: size
                )
            }

            coverTypography
        }
        .frame(width: size, height: size)
        .buFiSurface(
            cornerRadius: cornerRadius,
            fill: .clear,
            stroke: BuFiTheme.separator.opacity(0.26),
            clipsContent: true
        )
        .accessibilityHidden(true)
    }

    private var coverTypography: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: max(4, size * 0.025)) {
                Image(systemName: "waveform")
                    .font(.system(size: max(8, size * 0.045), weight: .bold))
                Text("BUFI SMART")
                    .font(.system(size: max(8, size * 0.043), weight: .black))
                    .tracking(size * 0.004)
                Spacer(minLength: 4)
                Text(String(format: "%02d", min(mix.songs.count, 99)))
                    .font(
                        .system(
                            size: max(8, size * 0.043),
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.88))

            Spacer(minLength: 0)

            Text(coverTitle)
                .font(coverFont)
                .tracking(-size * 0.006)
                .lineLimit(mix.kind == .artist ? 2 : 3)
                .minimumScaleFactor(0.62)
                .fixedSize(horizontal: false, vertical: true)

            Text(coverTheme.signature)
                .font(
                    .system(
                        size: max(8, size * 0.047),
                        weight: .bold,
                        design: .rounded
                    )
                )
                .tracking(size * 0.003)
                .foregroundStyle(.white.opacity(0.68))
                .padding(.top, max(4, size * 0.022))
        }
        .foregroundStyle(.white)
        .padding(max(13, size * 0.075))
        .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
    }

    private var coverTitle: String {
        switch mix.kind {
        case .daylist: "DAYLIST"
        case .repeatListening: "REPEAT"
        case .listenAgain: "LISTEN\nAGAIN"
        case .favorites: "FAVORITES"
        case .ranking: "TOP\nTRACKS"
        case .artist:
            mix.title
                .replacingOccurrences(of: " Mix", with: "")
                .uppercased() + " MIX"
        case .genre, .mood: mix.title.uppercased()
        }
    }

    private var coverFont: Font {
        let fontSize = max(18, size * (mix.kind == .artist ? 0.105 : 0.118))
        let supportsUnbounded = coverTitle.unicodeScalars.allSatisfy {
            $0.isASCII
        }
        if supportsUnbounded {
            return .custom("Unbounded-Black", fixedSize: fontSize)
        }
        return .system(
            size: fontSize,
            weight: .black,
            design: .rounded
        )
    }

    private var coverTheme: SmartMixCoverTheme {
        switch mix.kind {
        case .daylist:
            if mix.id.hasSuffix("-night") {
                return .init(
                    colors: [
                        Color(red: 0.025, green: 0.035, blue: 0.12),
                        Color(red: 0.10, green: 0.18, blue: 0.54),
                        Color(red: 0.28, green: 0.23, blue: 0.60)
                    ],
                    accent: Color(red: 0.48, green: 0.88, blue: 0.94),
                    symbol: "moon.stars.fill",
                    signature: "AFTER DARK"
                )
            }
            if mix.id.hasSuffix("-afternoon") {
                return .init(
                    colors: [
                        Color(red: 0.30, green: 0.04, blue: 0.20),
                        Color(red: 0.92, green: 0.20, blue: 0.32),
                        Color(red: 1.0, green: 0.58, blue: 0.27)
                    ],
                    accent: Color(red: 1.0, green: 0.88, blue: 0.48),
                    symbol: "sun.horizon.fill",
                    signature: "GOLDEN HOUR"
                )
            }
            return .init(
                colors: [
                    Color(red: 0.18, green: 0.07, blue: 0.46),
                    Color(red: 0.42, green: 0.20, blue: 0.95),
                    Color(red: 0.92, green: 0.48, blue: 0.82)
                ],
                accent: Color(red: 1.0, green: 0.87, blue: 0.42),
                symbol: "sun.max.fill",
                signature: "RIGHT NOW"
            )
        case .repeatListening:
            return .init(
                colors: [
                    Color(red: 0.02, green: 0.08, blue: 0.22),
                    Color(red: 0.02, green: 0.34, blue: 0.88),
                    Color(red: 0.08, green: 0.66, blue: 0.72)
                ],
                accent: Color(red: 0.78, green: 1.0, blue: 0.70),
                symbol: "repeat",
                signature: "ON ROTATION"
            )
        case .listenAgain:
            return .init(
                colors: [
                    Color(red: 0.24, green: 0.07, blue: 0.02),
                    Color(red: 0.82, green: 0.27, blue: 0.04),
                    Color(red: 0.98, green: 0.62, blue: 0.20)
                ],
                accent: Color(red: 1.0, green: 0.91, blue: 0.66),
                symbol: "clock.arrow.circlepath",
                signature: "BACK IN TIME"
            )
        case .genre:
            return .init(
                colors: [
                    Color(red: 0.03, green: 0.12, blue: 0.08),
                    Color(red: 0.16, green: 0.47, blue: 0.16),
                    Color(red: 0.50, green: 0.70, blue: 0.06)
                ],
                accent: Color(red: 0.88, green: 1.0, blue: 0.34),
                symbol: "waveform",
                signature: "DEEP CUTS"
            )
        case .artist:
            return .init(
                colors: [.black, Color(red: 0.56, green: 0.12, blue: 0.36)],
                accent: Color(red: 1.0, green: 0.50, blue: 0.72),
                symbol: "music.mic",
                signature: "ARTIST RADIO"
            )
        case .mood:
            if mix.id.hasPrefix("happy-mix") {
                return .init(
                    colors: [
                        Color(red: 0.48, green: 0.14, blue: 0.00),
                        Color(red: 0.98, green: 0.46, blue: 0.02),
                        Color(red: 1.0, green: 0.76, blue: 0.16)
                    ],
                    accent: Color(red: 1.0, green: 0.96, blue: 0.68),
                    symbol: "sparkles",
                    signature: "PURE JOY"
                )
            }
            if mix.id.hasPrefix("upbeat-mix") {
                return .init(
                    colors: [
                        Color(red: 0.28, green: 0.01, blue: 0.09),
                        Color(red: 0.94, green: 0.05, blue: 0.28),
                        Color(red: 0.98, green: 0.34, blue: 0.12)
                    ],
                    accent: Color(red: 1.0, green: 0.86, blue: 0.30),
                    symbol: "bolt.fill",
                    signature: "HIGH ENERGY"
                )
            }
            if mix.id.hasPrefix("chill-mix") {
                return .init(
                    colors: [
                        Color(red: 0.02, green: 0.10, blue: 0.15),
                        Color(red: 0.02, green: 0.40, blue: 0.48),
                        Color(red: 0.25, green: 0.66, blue: 0.66)
                    ],
                    accent: Color(red: 0.84, green: 1.0, blue: 0.94),
                    symbol: "water.waves",
                    signature: "SLOW FLOW"
                )
            }
            return .init(
                colors: [
                    Color(red: 0.11, green: 0.05, blue: 0.28),
                    Color(red: 0.48, green: 0.13, blue: 0.58),
                    Color(red: 0.88, green: 0.35, blue: 0.62)
                ],
                accent: Color(red: 0.94, green: 0.76, blue: 1.0),
                symbol: "heart.circle.fill",
                signature: "FEEL IT"
            )
        case .favorites:
            return .init(
                colors: [
                    Color(red: 0.13, green: 0.02, blue: 0.22),
                    Color(red: 0.46, green: 0.08, blue: 0.72),
                    Color(red: 0.92, green: 0.18, blue: 0.56)
                ],
                accent: Color(red: 0.52, green: 1.0, blue: 0.82),
                symbol: "heart.fill",
                signature: "ALL YOURS"
            )
        case .ranking:
            return .init(
                colors: [
                    Color(red: 0.02, green: 0.05, blue: 0.18),
                    Color(red: 0.08, green: 0.24, blue: 0.78),
                    Color(red: 0.30, green: 0.20, blue: 0.92)
                ],
                accent: Color(red: 0.48, green: 0.96, blue: 0.88),
                symbol: "chart.bar.fill",
                signature: "YOUR CHART"
            )
        }
    }
}

private struct SmartMixCoverTheme {
    let colors: [Color]
    let accent: Color
    let symbol: String
    let signature: String
}

private struct SmartMixCoverBackground: View {
    let theme: SmartMixCoverTheme
    let size: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: theme.colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Canvas { context, canvas in
                let unit = min(canvas.width, canvas.height) / 512
                let center = CGPoint(
                    x: canvas.width * 0.70,
                    y: canvas.height * 0.42
                )

                for index in 0..<4 {
                    let diameter = CGFloat(150 + (index * 58)) * unit
                    let rect = CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(
                            theme.accent.opacity(0.27 - Double(index) * 0.045)
                        ),
                        lineWidth: max(1, 3.2 * unit)
                    )
                }

                var wave = Path()
                let baseY = canvas.height * 0.71
                for step in 0...24 {
                    let progress = CGFloat(step) / 24
                    let x = progress * canvas.width
                    let y = baseY
                        + sin(progress * .pi * 4.2) * 15 * unit
                        + cos(progress * .pi * 1.7) * 7 * unit
                    if step == 0 {
                        wave.move(to: CGPoint(x: x, y: y))
                    } else {
                        wave.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(
                    wave,
                    with: .color(.white.opacity(0.22)),
                    style: StrokeStyle(
                        lineWidth: max(1, 4 * unit),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

                for index in 0..<11 {
                    let x = CGFloat((index * 83 + 41) % 470) * unit
                    let y = CGFloat((index * 137 + 54) % 360) * unit
                    let dot = CGRect(
                        x: x,
                        y: y,
                        width: max(1.5, CGFloat(3 + index % 3) * unit),
                        height: max(1.5, CGFloat(3 + index % 3) * unit)
                    )
                    context.fill(
                        Path(ellipseIn: dot),
                        with: .color(.white.opacity(0.20))
                    )
                }
            }

            Circle()
                .fill(.white.opacity(0.10))
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.24), lineWidth: max(0.8, size * 0.006))
                }
                .frame(width: size * 0.35, height: size * 0.35)
                .overlay {
                    Image(systemName: theme.symbol)
                        .font(
                            .system(
                                size: size * 0.15,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(theme.accent)
                }
                .offset(x: size * 0.20, y: -size * 0.12)
        }
    }
}

struct PersonalizedMixCard: View {
    let mix: PersonalizedMix
    var width: CGFloat = 166

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PersonalizedMixArtwork(
                mix: mix,
                size: width,
                cornerRadius: 16
            )
            Text(mix.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(height: 38, alignment: .topLeading)
            Text(mix.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(height: 34, alignment: .topLeading)
        }
        .frame(width: width, height: width + 88, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .combine)
    }
}

struct PersonalizedMixDetailView: View {
    let mix: PersonalizedMix
    private let audio = AudioEngine.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                hero
                controls
                songs
            }
            .padding(.top, 12)
            .buFiMiniPlayerContentClearance(idle: 56, playing: 148)
        }
        .background(BuFiScreenBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var hero: some View {
        VStack(spacing: 16) {
            PersonalizedMixArtwork(
                mix: mix,
                size: 250,
                cornerRadius: 24
            )
            VStack(spacing: 7) {
                Text(mix.title)
                    .font(.system(size: 29, weight: .bold))
                    .tracking(-0.8)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(mix.subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text(
                String(
                    format: String(localized: "%d곡"),
                    mix.songs.count
                )
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                play(mix.songs)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(
                        BuFiTheme.elevated,
                        in: Circle()
                    )
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel("셔플 재생")

            Button {
                guard let first = mix.songs.first else { return }
                audio.play(first, in: mix.songs)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(BuFiTheme.accent, in: Circle())
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel("전체 재생")
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var songs: some View {
        if mix.songs.isEmpty {
            ContentUnavailableView(
                "재생할 곡이 없습니다",
                systemImage: "music.note"
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        } else {
            BuFiGroupedSurface {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(mix.songs.enumerated()),
                        id: \.offset
                    ) { index, song in
                        HStack(spacing: mix.showsRanking ? 10 : 2) {
                            if mix.showsRanking {
                                Text("\(index + 1)")
                                    .font(
                                        .system(
                                            size: 14,
                                            weight: index < 3 ? .bold : .medium,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(
                                        index < 3
                                            ? BuFiTheme.accent
                                            : Color.secondary
                                    )
                                    .monospacedDigit()
                                    .frame(width: 24, alignment: .trailing)
                            }
                            SongRow(
                                song: song,
                                queue: mix.songs,
                                queueIndex: index,
                                artworkSize: 52,
                                textLineLimit: 2
                            )
                        }
                        .padding(.horizontal, 12)

                        if index < mix.songs.count - 1 {
                            Divider()
                                .padding(.leading, mix.showsRanking ? 112 : 78)
                                .opacity(0.50)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func play(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        var generator = SystemRandomNumberGenerator()
        let shuffled = songs.shuffled(using: &generator)
        guard let first = shuffled.first else { return }
        audio.play(first, in: shuffled)
    }
}
