from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}: {old[:140]!r}")
    path.write_text(text.replace(old, new, 1))


player = Path("BuFi/UI/PlayerView.swift")
replace_once(player, "                artistImageUrl: nil,\n", "")

audio = Path("BuFi/Playback/AudioEngine.swift")
replace_once(
    audio,
    '''                if let song = self.currentSong {
                    self.restartPlaybackPlan(resumeFrom: self.elapsed)
                }
''',
    '''                if self.currentSong != nil {
                    self.restartPlaybackPlan(resumeFrom: self.elapsed)
                }
''',
)

artwork = Path("BuFi/Core/ArtworkStore.swift")
text = artwork.read_text()
count = text.count("await pipeline.cache.removeAll")
if count != 4:
    raise RuntimeError(f"{artwork}: expected four obsolete awaits, found {count}")
artwork.write_text(text.replace("await pipeline.cache.removeAll", "pipeline.cache.removeAll"))
