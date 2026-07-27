from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


player_path = "BuFi/UI/PlayerView.swift"
player = read(player_path)
player = replace_once(player, '    @State private var artworkPage = 0\n', '    @State private var artworkPage = 0\n    @State private var transitionDirection: CGFloat = 1\n', "player direction state")
player = replace_once(player, '                            artwork(song, availableHeight: proxy.size.height)\n                            metadata(song)\n', '                            nowPlayingPager(song, availableHeight: proxy.size.height)\n', "combined now-playing pager")
player = replace_once(player, '        .onChange(of: audio.queueIndex) { _, index in\n            syncArtworkPage(to: index, animated: true)\n', '        .onChange(of: audio.queueIndex) { oldIndex, index in\n            transitionDirection = index >= oldIndex ? 1 : -1\n            syncArtworkPage(to: index, animated: true)\n', "queue direction tracking")
player = replace_once(player, '                .transition(.opacity)\n', '''                .transition(
                    motionEnabled
                        ? .asymmetric(
                            insertion: .move(edge: transitionDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: transitionDirection > 0 ? .leading : .trailing).combined(with: .opacity)
                        )
                        : .opacity
                )
''', "header horizontal transition")
player = replace_once(player, '            .animation(.easeInOut(duration: 0.28), value: song.id)\n', '            .animation(BuFiMotion.text, value: song.id)\n', "header animation")
player = replace_once(player, '        .animation(.easeInOut(duration: 0.34), value: palette)\n', '        .animation(BuFiMotion.color, value: palette)\n', "palette animation")
marker = '    private func artwork(_ song: Song, availableHeight: CGFloat) -> some View {\n'
if marker not in player:
    raise RuntimeError("artwork function marker missing")
pager = '''    private func nowPlayingPager(_ song: Song, availableHeight: CGFloat) -> some View {
        let edge = min(UIScreen.main.bounds.width - 44, max(264, availableHeight * 0.47))
        let songs = audio.queue.isEmpty ? [song] : audio.queue

        return TabView(selection: $artworkPage) {
            ForEach(Array(songs.enumerated()), id: \\.offset) { index, item in
                VStack(spacing: 0) {
                    ArtworkView(
                        coverArt: item.coverArt,
                        size: edge,
                        cornerRadius: 14,
                        onPalette: { nextPalette in
                            guard index == artworkPage else { return }
                            withAnimation(BuFiMotion.color) { palette = nextPalette }
                        }
                    )
                    .frame(width: edge, height: edge)
                    .shadow(color: .black.opacity(0.34), radius: 25, y: 15)
                    .padding(.horizontal, 4)
                    .padding(.top, 13)
                    .padding(.bottom, 26)

                    metadataContent(item)
                        .padding(.bottom, 18)
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: edge + 116)
        .contentShape(Rectangle())
        .onChange(of: artworkPage) { oldIndex, index in
            transitionDirection = index >= oldIndex ? 1 : -1
            guard index != audio.queueIndex,
                  audio.queue.indices.contains(index) else { return }
            audio.playQueueItem(at: index)
        }
        .animation(motionEnabled ? BuFiMotion.player : .none, value: artworkPage)
    }

'''
player = player.replace(marker, pager + marker, 1)
player = player.replace('motionEnabled ? .easeOut(duration: 0.30) : .none', 'motionEnabled ? BuFiMotion.fade : .none')
player = player.replace('motionEnabled ? .easeOut(duration: 0.32) : .none', 'motionEnabled ? BuFiMotion.lyrics : .none')
player = player.replace('withAnimation(.easeInOut(duration: 0.36)) {\n                artworkPage = resolved\n            }', 'withAnimation(BuFiMotion.player) {\n                artworkPage = resolved\n            }')
write(player_path, player)

write("BuFi/UI/BuFiMotion.swift", '''import SwiftUI

enum BuFiMotion {
    static let tap = Animation.interactiveSpring(response: 0.34, dampingFraction: 0.84, blendDuration: 0.06)
    static let player = Animation.interactiveSpring(response: 0.44, dampingFraction: 0.89, blendDuration: 0.08)
    static let page = Animation.easeOut(duration: 0.20)
    static let fade = Animation.easeOut(duration: 0.24)
    static let text = Animation.easeInOut(duration: 0.32)
    static let color = Animation.easeInOut(duration: 0.38)
    static let lyrics = Animation.easeOut(duration: 0.36)
}
''')

components_path = "BuFi/UI/Components.swift"
components = read(components_path)
components = replace_once(components, '            .scaleEffect(configuration.isPressed ? 0.965 : 1)\n            .brightness(configuration.isPressed ? -0.025 : 0)\n            .animation(\n                .interactiveSpring(response: 0.28, dampingFraction: 0.72, blendDuration: 0.08),\n                value: configuration.isPressed\n            )\n', '            .scaleEffect(configuration.isPressed ? 0.972 : 1)\n            .brightness(configuration.isPressed ? -0.018 : 0)\n            .animation(BuFiMotion.tap, value: configuration.isPressed)\n', "shared press motion")
write(components_path, components)

root_path = "BuFi/UI/RootView.swift"
root = read(root_path)
root = root.replace('motionEnabled ? .easeOut(duration: 0.18) : .none', 'motionEnabled ? BuFiMotion.page : .none')
root = root.replace('.interactiveSpring(response: 0.38, dampingFraction: 0.82)', 'BuFiMotion.player')
write(root_path, root)

mini_path = "BuFi/UI/LegacyMiniPlayerView.swift"
mini = read(mini_path)
mini = mini.replace('.interactiveSpring(response: 0.42, dampingFraction: 0.84)', 'BuFiMotion.player')
mini = mini.replace('.shadow(color: .black.opacity(0.24), radius: 10, y: 5)', '.shadow(color: .black.opacity(0.20), radius: 12, y: 6)')
write(mini_path, mini)

project_path = "project.yml"
project = read(project_path)
project = project.replace('CFBundleShortVersionString: "1.2.7"', 'CFBundleShortVersionString: "1.3.0"')
project = project.replace('CFBundleVersion: "11"', 'CFBundleVersion: "12"')
project = project.replace('MARKETING_VERSION: "1.2.7"', 'MARKETING_VERSION: "1.3.0"')
project = project.replace('CURRENT_PROJECT_VERSION: "11"', 'CURRENT_PROJECT_VERSION: "12"')
write(project_path, project)

settings_path = "BuFi/UI/SettingsView.swift"
settings = read(settings_path)
settings = settings.replace('?? "1.2.7"', '?? "1.3.0"')
settings = settings.replace('?? "11"', '?? "12"')
write(settings_path, settings)

(ROOT / ".github/scripts/apply-motion-1.3.py").unlink(missing_ok=True)
(ROOT / ".github/workflows/apply-motion-1.3.yml").unlink(missing_ok=True)
