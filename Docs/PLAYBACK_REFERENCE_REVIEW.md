# Playback stability reference review

Reviewed on 2026-07-29. These projects were used as architectural
references; no source was copied into BuFi.

| Project | Reviewed revision | License | Patterns applied to BuFi |
| --- | --- | --- | --- |
| Pocket Casts iOS | `9af186a` | MPL-2.0 | Keep queue state separate from the active player, persist progress in batches, treat interruption and route events as explicit playback state transitions, and avoid blocking the UI while audio-session work is negotiated. |
| TIDAL iOS SDK | `95c8a8b` | Apache-2.0 | Serialize player-side operations, coalesce monitor-driven work, keep observer lifetimes tied to the active item, cancel obsolete tasks, and preserve active playback while releasing speculative resources. |
| Telegram iOS | `6ad963e` | The project README requires source publication for license compliance; bundled components carry their own licenses | Keep UI mutations on the main thread, serialize dependent transactions, bound reusable caches, and release derived data under memory pressure. |

## Resulting BuFi decisions

- `AVAudioSession` configuration and activation are serialized by an actor,
  performed away from `MainActor`, and duplicate activation requests are
  coalesced.
- A media-services reset invalidates the audio-session state before rebuilding
  the active item.
- Interruption recovery records intent and marks the session inactive without
  discarding the current queue.
- `MPNowPlayingSession` activation is coalesced so repeated metadata refreshes
  cannot create an unbounded set of activation tasks.
- Queue JSON encoding runs at utility priority instead of blocking player UI
  updates.
- A memory warning keeps the active item and in-flight visible detail requests,
  while clearing reusable detail/artwork caches and cancelling speculative
  offline prefetch.

## Deliberately not adopted

- BuFi was not migrated from `AVPlayer` to TIDAL's `AVQueuePlayer` architecture.
  That is a large engine change with higher regression risk for OpenSubsonic
  transcoding, seeking, lyrics, and existing queue restoration. Gapless
  playback should be introduced as a separately tested engine milestone.
- Pocket Casts and Telegram implementation code was not copied. This keeps
  BuFi's licensing boundaries clear and makes the changes fit its existing
  SwiftUI/OpenSubsonic design.
