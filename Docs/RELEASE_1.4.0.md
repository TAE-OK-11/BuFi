# BuFi 1.4.0

## Architecture

- Uses SwiftSonic (MIT) for the hardened salted-token authentication check, transient retry path, and authenticated media URL construction.
- Uses Nuke and NukeUI (MIT) for album-art downsampling, request coalescing, background decoding, and bounded memory/disk caching.
- Preserves BuFi's existing domain model mapping while the remaining metadata endpoints are migrated incrementally.
- References Cassette's independent playback-manager and minimal-observation architecture without copying MPL-2.0 source files.

## Offline playback

- Atomic audio downloads with duplicate-request coalescing.
- Persistent offline index with legacy-cache compatibility.
- Local-first playback and configurable 0/1/3 upcoming-track prefetch.
- Wi-Fi-only download option and low-power-mode prefetch limiting.
- Configurable 5/10/25 GB or unlimited storage, with least-recently-used cleanup.

## UI and energy

- Light-mode contrast fixes for artist, album, playlist controls and settings surfaces.
- Album-image requests are resized for their actual display size instead of decoding oversized originals.
- Image memory is bounded and reusable disk data is cached to reduce repeated network requests and battery use.

## Verification

- Pull requests are compiled with the Xcode 26 unsigned-device build and the Xcode 27 iOS SDK compatibility build before merge.
- Concise Xcode failure logs are retained as CI artifacts so compiler regressions can be corrected without guessing.
