from pathlib import Path

path = Path("BuFi/Core/RecommendationEngine.swift")
text = path.read_text()

old = '''        let temporalProfiles = temporalProfiles(
            from: allBehaviors,
            shortCutoff: shortCutoff,
            longCutoff: longCutoff,
            date: evaluationDate
        )
        let shortProfile = temporalProfiles.short
        let longProfile = temporalProfiles.long
'''
new = '''        let profiles = temporalProfiles(
            from: allBehaviors,
            shortCutoff: shortCutoff,
            longCutoff: longCutoff,
            date: evaluationDate
        )
        let shortProfile = profiles.short
        let longProfile = profiles.long
'''
if text.count(old) != 1:
    raise SystemExit("unexpected temporal profile declaration")
text = text.replace(old, new, 1)

old = '''        let favoriteProfile = profile(
            from: snapshot.starredSongs.map {
                behavior.songs[$0.id]
                    ?? SongBehavior(song: $0, at: evaluationDate)
            },
            date: evaluationDate,
            appliesDecay: false
        )
'''
new = '''        let favoriteProfile = profile(
            from: snapshot.starredSongs.map { song in
                var value = behavior.songs[song.id]
                    ?? SongBehavior(song: song, at: evaluationDate)
                // Preserve behavioral evidence but always derive preference
                // dimensions from the authoritative current starred metadata.
                value.song = song
                return value
            },
            date: evaluationDate,
            appliesDecay: false
        )
'''
if text.count(old) != 1:
    raise SystemExit("unexpected favorite profile declaration")
text = text.replace(old, new, 1)

path.write_text(text)
