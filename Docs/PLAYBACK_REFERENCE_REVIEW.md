# Playback stability reference review

Reviewed on 2026-08-11. These projects were used as architectural
references; no source was copied into BuFi.

| Project | Reviewed revision | License | Patterns applied to BuFi |
| --- | --- | --- | --- |
| Pocket Casts iOS | `9af186a` | MPL-2.0 | Keep queue state separate from the active player, persist progress in batches, treat interruption and route events as explicit playback state transitions, and avoid blocking the UI while audio-session work is negotiated. |
| TIDAL iOS SDK | `41aed3a` | Apache-2.0 | Serialize player-side operations, coalesce keyed requests, keep AVPlayer observer lifetimes tied to their owner, use bounded constrained-network scheduling and jittered backoff, cancel obsolete tasks, and preserve active playback while releasing speculative resources. |
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
- Timeline publication remains periodic for efficient seek-bar updates, while
  synchronized lyrics use boundary-time events and generation-checked immediate
  recalculation after seeks, recovery, and item replacement.
- Safe read-only OpenSubsonic requests use a small, jittered retry budget and
  respect server `Retry-After`; authentication, decoding, cancellation, and
  mutation failures are never retried automatically.
- A memory warning keeps the active item and in-flight visible detail requests,
  while clearing reusable detail/artwork caches and cancelling speculative
  offline prefetch.
- Full-player, mini-player, queue, and system now-playing artwork use the visual
  identity `(song ID, coverArt ID)`. A transient queue/current-item publication
  mismatch therefore renders the current song directly instead of exposing the
  previous queue entry's cover.
- Every AVPlayer waiting transition starts one bounded watchdog. The watchdog
  is armed only for startup freeze (elapsed under 1.5s) or a genuine stall.
  A healthy playing clock cancels it. HTTP 4xx stream failures fail closed
  instead of cycling codecs. Transport retries use 400/900ms backoff. The
  watchdog still forces an immediate-rate retry, performs one exact near-zero
  seek nudge for a stream that never leaves `0:00`, reloads the active format
  at most twice, then tries a bandwidth-bounded compatibility format.
- Network-path loss pauses speculative work and leaves playback intent intact;
  path restoration immediately resumes AVPlayer and re-arms the watchdog. A
  confirmed playing state cancels recovery and resets its budget only after an
  eight-second stability window.

## Energy pass

- Ordinary album and artist artwork no longer runs palette extraction unless
  a screen actually consumes the result.
- Playback progress refreshes at 4 Hz only while the full player is visible and
  at 2 Hz elsewhere. Duration checks, scrobbling, and queue persistence are
  batched to at most once per playback second.
- Player artwork prefetch is limited to the immediate successor at 600 pixels
  instead of decoding two 900-pixel successors.
- Entering Low Power Mode or a serious thermal state cancels optional external
  recommendation work and offline prefetch without interrupting playback.
- Low Power Mode restores the system auto-lock behavior even when the optional
  keep-screen-awake playback setting is enabled.
- Optional Last.fm and ListenBrainz requests avoid constrained networks and
  limit connection concurrency.
- A paused player deactivates its audio session after a short resume window;
  an idle player entering the background deactivates immediately.
- Release builds use explicit modules, whole-module Swift optimization, and
  monolithic LTO. CI skips redundant clean passes and Homebrew auto-update work.

## Release optimizer follow-up

- `LLVM_LTO = YES` combines the executable into one link-time optimization
  unit. This deliberately trades longer links and higher CI memory use for the
  strongest cross-file optimization.
- Swift remains on safe `-O` whole-module optimization. `-Ounchecked` and
  disabled exclusivity or safety checks are intentionally excluded because
  playback and networking correctness matter more than an unmeasured
  micro-optimization.
- Xcode 26 compilation caching and explicit modules reduce repeated compilation
  work.
- Release deployment postprocessing, safe non-global stripping, dead-code
  stripping, and product validation keep the shipped executable lean while
  retaining a dSYM for crash symbolication. Swift symbol stripping remains
  disabled for the documented Xcode 26.3–27 beta device-launch workaround.

Official references:

- Apple Xcode Build Settings Reference:
  <https://developer.apple.com/documentation/xcode/build-settings-reference>
- Apple Xcode 26 Release Notes — compilation caching:
  <https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes>
- Swift.org Whole-Module Optimization:
  <https://www.swift.org/blog/whole-module-optimizations/>

## Deliberately not adopted

- BuFi uses `AVQueuePlayer` only as a bounded two-item transport window. The
  app's account-scoped logical queue remains authoritative, and only the
  current item plus one validated deterministic successor is staged. Shuffle,
  repeat-one, quality changes, queue edits, and account changes invalidate that
  successor. This provides gapless hand-off without adopting an SDK-specific
  queue model.
- Crossfade and a custom byte-range resource loader were not adopted. Direct
  and downloaded assets can use deterministic staging; server-transcoded
  streams remain best effort and fall back to the normal bounded recovery and
  codec-compatibility plan.
- Pocket Casts and Telegram implementation code was not copied. This keeps
  BuFi's licensing boundaries clear and makes the changes fit its existing
  SwiftUI/OpenSubsonic design.
- TIDAL's repository does not provide a reusable SwiftUI player design, a lyric
  synchronization engine, or artwork-palette extraction. BuFi therefore keeps
  its established UI and implements those capabilities locally instead of
  introducing an unrelated SDK dependency.
