# Device verification checklist

BuFi's AirPlay, background audio, scrobbling, gapless+shuffle, AAC-320
passthrough, and cross-client star refresh paths cannot be fully exercised on
Linux CI or the iOS Simulator. Run these on a physical iPhone after signing a
Debug/Release build against a real OpenSubsonic/Navidrome server.

Use one account with known AAC-320 files, at least one lossless/ALAC or FLAC
file, a library large enough for shuffle, and a second client (web UI or
another app) that can star/unstar the same songs.

## 1. AirPlay

1. Start playback of a remote stream (not an offline-only file).
2. Route to an AirPlay speaker/TV from Control Center.
3. Confirm audio continues on the AirPlay device without restarting the track
   from 0:00 (small seek/resync is OK).
4. Pause / play from both BuFi and the AirPlay receiver controls.
5. Skip forward once; confirm Now Playing metadata (title/artist/artwork)
   updates on the Lock Screen and on the AirPlay device.
6. Disconnect AirPlay mid-track; confirm playback returns to the phone speaker
   (or the previous route) without a crash or stuck buffering spinner.
7. Repeat once with **AAC-320** quality and once with **Automatic**.

## 2. Background playback

1. Start playback, then leave BuFi (Home gesture) and lock the device.
2. Confirm audio continues for at least two track transitions (or 3+ minutes
   on a long track).
3. From Lock Screen / Dynamic Island: pause, play, next, previous.
4. Force a brief network blip (Airplane Mode 2–3s, then off) while locked;
   confirm recovery or a clear buffering state without silent stall forever.
5. Open another audio app briefly if available, then return focus to BuFi and
   confirm session hand-off behaves as expected (no zombie dual audio).
6. After backgrounding ≥5 minutes, unlock, reopen BuFi, and confirm queue
   index, shuffle/repeat, and elapsed time still match what you hear.

## 3. Scrobbling

1. On the server (or ListenBrainz/Last.fm if wired through the server), note
   the current play count / last scrobble for a test song.
2. Play that song past BuFi's submission threshold (half duration, floored at
   30s and capped at 240s).
3. Confirm one scrobble/submission appears; scrubbing back and forth inside
   the same play must not create duplicates.
4. Toggle Airplane Mode **before** the threshold, cross the threshold offline,
   then restore network while the same song is still playing. Confirm a
   scrobble is eventually submitted (retry path) without two submissions.
5. Skip before the threshold; confirm **no** scrobble.
6. Change tracks immediately after a successful scrobble; confirm the next
   track can scrobble independently.

## 4. Gapless + shuffle

1. Disable shuffle. Play a short-track playlist and listen across 2–3
   boundaries. Confirm no audible double-load gap beyond normal decoder
   priming; Now Playing index advances once per boundary.
2. Enable shuffle mid-playlist. Confirm the next track is **not** the old
   linear successor (order changes) and that gapless staging does not force
   the wrong song.
3. With shuffle on, let a track approach its end. Confirm autoplay /
   continuation (if enabled) still works when the shuffle session exhausts
   unplayed entries, without pausing forever or inserting the linear next.
4. Toggle shuffle off again; confirm upcoming order returns to a coherent
   linear plan and gapless prep may resume for the true successor.
5. Stress: rapid next/prev during the last ~15s of a track (staging window).
   Confirm no crash, no two items audible, and queue index stays consistent.

## 5. AAC-320 passthrough

1. Pick a song whose server file is AAC near 320 kbps (Apple AAC or FDK-AAC).
2. Set quality to **AAC 320**. Start playback and inspect the active stream
   (server logs, proxy, or BuFi debug/network tooling if available): prefer
   raw/passthrough rather than a re-encode when the source is already
   compliant.
3. Pick a higher-rate or non-AAC source. Confirm BuFi requests an AAC
   transcode (or documented fallback) instead of claiming passthrough.
4. Seek and skip on a passthrough track; confirm no decode error loop and
   that fallback to `aac`/`mp3` still runs if the raw item fails.
5. Switch quality from AAC-320 → Original → AAC-320 on the same track;
   confirm the player rebuilds the item cleanly.

## 6. Cross-client star / unstar home refresh

1. On BuFi Home, note a song in **Liked / Starred**.
2. On a second client, unstar that song (and optionally star a different one).
3. Return to BuFi and trigger Home refresh (pull-to-refresh or navigation
   back to Home). Confirm the starred list matches the server—no stale
   “liked” chip for the unstarred song.
4. From BuFi, star a song while a Home refresh is already in flight (tap star
   during pull-to-refresh). Confirm the optimistic star wins until the server
   confirms, and the next completed refresh does not flash the old state.
5. Rapidly star → unstar → star the same song. Confirm the final UI state
   matches the last successful mutation and Home does not reopen a stale
   starred payload from a request that started mid-mutation.
6. Airplane Mode: star offline (expect failure/rollback), restore network,
   star again; confirm Home refresh afterwards is consistent.

## Sign-off

| Area | Device / iOS | Build | Pass | Notes |
| --- | --- | --- | --- | --- |
| AirPlay | | | | |
| Background playback | | | | |
| Scrobbling | | | | |
| Gapless + shuffle | | | | |
| AAC-320 passthrough | | | | |
| Cross-client star refresh | | | | |

Tester: ______________  Date (KST): ______________
