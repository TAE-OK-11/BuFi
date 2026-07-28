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

- Adds a selectable player-control style: Apple’s native Liquid Glass slider
  and glass buttons on iOS 26+, with an automatic Classic fallback on iOS
  17–25.
- Centralizes motion policy so Reduce Motion, Low Power Mode, and serious or
  critical thermal pressure suppress nonessential transitions consistently.
- Light-mode contrast fixes for artist, album, playlist controls and settings surfaces.
- Album-image requests are resized for their actual display size instead of decoding oversized originals.
- Image memory is bounded and reusable disk data is cached to reduce repeated network requests and battery use.

## Stability

- Serializes rapid favorite mutations and protects confirmed server state from
  stale search, detail, and home responses.
- Hardens playback recovery, queue restoration, logout cleanup, route changes,
  terminal item failures, and duplicate-song queue presentation.
- Coalesces concurrent detail, artwork, and offline-download work while
  preventing cancelled waiters or an old account scope from publishing stale
  results.

## Verification

- Pull requests are compiled with the Xcode 26.6 unsigned-device build; an advisory Xcode 27 beta job checks the iOS 27 SDK without making preview-runner availability a merge gate.
- Xcode 27 logs are retained on every run so new SDK warnings can be reviewed before they become stable-toolchain errors.
