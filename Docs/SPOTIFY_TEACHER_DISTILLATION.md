# Spotify Teacher Sequence Distillation

The two Notion pages are captures of Spotify recommendation output, not hand-authored BuFi playlists. They should therefore be treated as observations of a recommender policy. The goal is to distill stable placement behavior rather than memorize exact title co-occurrence.

## Coverage

The current parser resolves 21 independent Spotify runs across 13 seeds. Only two seeds have repeated captures: `Style (Taylor's Version)` has 6 runs and `Cruel Summer` has 4. The other 11 seeds currently have one observed run each, so their rank frequencies and recurrence intervals are lower-confidence evidence.

## High-confidence repeated-run findings

### Style (Taylor's Version) — Taylor Swift

- 6 captured runs, 8 recommendations per run.
- Mean unique-artist ratio: 0.917.
- Same-artist adjacent transition rate: 0.021.
- The seed artist returned in every run.
- Mean number of intervening tracks before a Taylor Swift return: 2.78; median: 3.
- No exact candidate dominated the runs. The highest observed exact-track recurrence was 0.333.

### Cruel Summer — Taylor Swift

- 4 captured runs, 8 recommendations per run.
- Mean unique-artist ratio: 0.875.
- Same-artist adjacent transition rate: 0.062.
- The seed artist returned in every run.
- Mean number of intervening tracks before a Taylor Swift return: 2.57; median: 4.
- The highest observed exact-track recurrence was 0.50.

## Aggregate structural signal

Across all captured runs, weighting by recommendation count, same-artist adjacency is about 1.7% and the unique-artist ratio is about 71%. Every captured seed run eventually returns to the seed artist, although recurrence-gap estimates for singleton seeds are low confidence. Longer lists naturally have lower unique-artist ratios because artists have more opportunities to return.

The strongest conclusion is that exact title identity is unstable while artist cadence is much more stable. Spotify appears to rotate records aggressively while keeping an artist/room rhythm. In the repeated Taylor runs, the seed artist behaves like an anchor that commonly returns after roughly three intervening records rather than forming a same-artist streak.

## Distillation policy

`BuFiRadioRecommender` item-Jaccard output should be treated as a weak teacher prior: evidence that two titles were observed in the same Spotify result, not proof of musical similarity. It must not dominate unseen or fresh songs.

The transition layer should learn sequence context explicitly. Training examples should preserve the original seed, previous track, candidate track, candidate rank/position, whether candidate artist equals the previous artist, whether it equals the original seed artist, whether that artist appeared in the recent 3 tracks, and the number of intervening tracks since that artist last appeared. Repeated captures should additionally contribute candidate appearance rate and rank stability as confidence weights.

At runtime, the 96-to-30 stage should select candidates sequentially rather than score every candidate as an independent seed pair. The learned transition score should be evaluated against the already selected prefix so artist-return cadence can influence later slots.

Exact candidate recurrence should remain a secondary signal because repeated Spotify runs show substantial title rotation. Audio and lyric features should be the generalization path for unseen songs.

## Missing input for feel-level distillation

The Notion captures contain ordered title/artist observations but do not contain BuFi's measured audio and AI lyric-analysis values. To distill *which feeling/audio shape follows which other feeling/audio shape* without guessing from song identity, training needs a current BuFi Library Scan Export covering the teacher songs. The export already contains BPM, audio energy, brightness, pulse, lyric energy/valence/intimacy, feel, moods, themes, emotional arc, sound labels, and analysis coverage. Once supplied, the Spotify sequence runs can be joined to those measured values and used to train a context-aware transition model.
