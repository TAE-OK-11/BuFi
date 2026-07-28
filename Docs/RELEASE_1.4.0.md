# BuFi 1.4.0

## Architecture

- Uses SwiftSonic (MIT) for salted-token authentication support and authenticated stream, artwork, and download URL construction.
- Uses the Nuke core product (MIT) for album-art downsampling, request coalescing, background decoding, and bounded memory/disk caching; the unused NukeUI product is not linked.
- Bundles the pinned SwiftSonic, Nuke, and Zstandard license texts and exposes them from the in-app open-source screen.
- Preserves BuFi's existing domain model mapping while the remaining metadata endpoints are migrated incrementally.
- References Cassette's independent playback-manager and minimal-observation architecture without copying MPL-2.0 source files.

## Offline playback

- Atomic audio downloads with duplicate-request coalescing.
- Persistent offline index with legacy-cache compatibility.
- Local-first playback and configurable 0/1/3 upcoming-track prefetch.
- Wi-Fi-only download option and low-power-mode prefetch limiting.
- Configurable 5/10/25 GB or unlimited storage, with least-recently-used cleanup.

## UI and energy

- Adds three selectable player styles: Classic preserves the original layout,
  Liquid Glass changes only the seek bar to Apple’s native control on iOS 26+,
  and Dynamic groups metadata, seek, transport, system volume, AirPlay, share,
  and queue controls in a Lock Screen-style glass card.
- Adds the separated artwork swipe and programmatic track-transition behavior
  to all three player styles while preserving the original full-width cover
  size and omitting the artwork drop shadow.
- Adds Original, Multicolor, and Bright player-background choices. The two new
  modes extract and cache up to three distinct album colors, then render a
  static Lock Screen-style gradient without continuous image analysis.
- Refines album palettes with deterministic OKLab clustering, perceptual color
  separation, pastel-aware scoring, and artwork-relative color positions so
  gradients preserve more of each cover’s actual color composition.
- Uses the refined supporting colors in Classic and Liquid Glass as subtle
  spatial highlights as well as in the stronger Multicolor, Bright, and
  Dynamic presentations.
- Smooths compact lyric progression and the compact-to-full-screen surface
  transition, shows up to five compact lyric lines, and allows long lines to
  wrap instead of truncating.
- Centralizes motion policy so Reduce Motion, Low Power Mode, and serious or
  critical thermal pressure suppress nonessential transitions consistently.
- Light-mode contrast fixes for artist, album, playlist controls and settings surfaces.
- Album-image requests are resized for their actual display size instead of decoding oversized originals.
- Image memory is bounded and reusable disk data is cached to reduce repeated network requests and battery use.

## Stability

- In Automatic quality, streams iPhone-native AAC, MP3, ALAC, and related
  sources unchanged, while requesting server-side AAC 256 kbps for FLAC, Opus,
  Vorbis, Ogg, and WebM sources; decode failures retain AAC/MP3 fallbacks.
- Serializes rapid favorite mutations and protects confirmed server state from
  stale search, detail, and home responses.
- Hardens playback recovery, queue restoration, logout cleanup, route changes,
  terminal item failures, and duplicate-song queue presentation.
- Coalesces concurrent detail, artwork, and offline-download work while
  preventing cancelled waiters or an old account scope from publishing stale
  results.
- Bounds expired detail caches, removes quadratic album-row classification, and
  clears the current Xcode 27 Swift concurrency warnings around player
  notifications and now-playing activation.
- Uses generation-checked stream and lyric requests so cancelled rapid track
  changes cannot publish stale player state, including repeated IDs.
- Stabilizes seek completion, pending seeks during item loading, end-of-track
  replay, buffering intent, pause-during-buffering, route/interruption resume,
  queue replacement, artwork palette cancellation, and lock-screen artwork
  refreshes.
- Renames the player background option from Original to Default. Default now
  uses a single album-derived color in Classic and Liquid Glass while Dynamic
  keeps its Lock Screen-style gradient.
- Removes the redundant system-volume bar from the Dynamic control card so the
  lower row contains only actionable sharing and queue controls.

## Verification

- Pull requests are compiled with the Xcode 26.6 unsigned-device build; an advisory Xcode 27 beta job checks the iOS 27 SDK without making preview-runner availability a merge gate.
- Xcode 27 logs are retained on every run so new SDK warnings can be reviewed before they become stable-toolchain errors.
