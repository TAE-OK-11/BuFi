from pathlib import Path

path = Path("BuFiTests/RecommendationEngineTests.swift")
text = path.read_text()

old1 = '''            snapshot: HomeSnapshot(
                serverRecommendedSongs: [staleFavorite, competitor],
                mostPlayedSongs: [competitor],
                starredSongs: [currentFavorite]
            ),'''
new1 = '''            snapshot: HomeSnapshot(
                starredSongs: [currentFavorite],
                serverRecommendedSongs: [staleFavorite, competitor],
                mostPlayedSongs: [competitor]
            ),'''
old2 = '''        let snapshot = HomeSnapshot(
            serverRecommendedSongs: [filler("s0"), consensus, filler("s2")],
            sonicRecommendedSongs: [filler("q0"), single, consensus],
            similarArtistSongs: [filler("m0"), consensus, filler("m2")],
            genreRecommendedSongs: [filler("g0"), consensus, filler("g2")]
        )'''
new2 = '''        let snapshot = HomeSnapshot(
            sonicRecommendedSongs: [filler("q0"), single, consensus],
            similarArtistSongs: [filler("m0"), consensus, filler("m2")],
            genreRecommendedSongs: [filler("g0"), consensus, filler("g2")],
            serverRecommendedSongs: [filler("s0"), consensus, filler("s2")]
        )'''

if new1 in text and new2 in text:
    raise SystemExit(0)
if text.count(old1) != 1 or text.count(old2) != 1:
    raise SystemExit("unexpected recommendation fixture shape")
path.write_text(text.replace(old1, new1, 1).replace(old2, new2, 1))
