# BuFi

BuFi is a native SwiftUI music client for Navidrome and OpenSubsonic servers.
It is designed around the iOS media stack rather than a web view.

## Current features

- Token-authenticated OpenSubsonic connection with credentials stored in Keychain
- Home, search, albums, artists, playlists, starred music, and server diagnostics
- Native `AVPlayer` playback with a persistent queue, shuffle, repeat, seeking, AirPlay, scrobbling, and background recovery
- Control Center, Lock Screen, Dynamic Island, wired-headset, and Bluetooth media controls through `MPNowPlayingSession`
- Automatic original streaming for iPhone-native AAC, MP3, ALAC, and related formats, with server-side AAC 256 kbps conversion for FLAC, Opus, Vorbis, and WebM sources
- Built-in speaker/route/interruption recovery and Subsonic MIME compatibility handling adapted from Amperfy
- Synchronized OpenSubsonic lyrics with smoothly morphing compact/full-screen views and multiline lyric wrapping
- Apple Music-led visual system with Spotify-style separated artwork paging, a subtle Deezer accent, and an optional native Liquid Glass seek bar on iOS 26+ while retaining Classic transport controls
- Deterministic OKLab artwork clustering with neutral-cover support, spatial multicolor fields, and a versioned GRDB palette cache
- Nuke-backed artwork request coalescing, caching, and downsampling
- HTTP/3 racing for API, artwork, and offline downloads; HTTP/2 fallback; gzip, Brotli, and bounded Zstandard API decoding
- In-flight API request coalescing, a 16 MiB bounded response cache, and energy-aware next-track lyrics/artwork/AVURLAsset preparation for instant skips
- Korean (default), English, and Japanese localization
- Favorite songs, albums, and artists, with favorite artists pinned above an indexed artist library
- Offline downloads stored in Application Support
- GitHub Actions generation of an unsigned IPA with Xcode 27 and Swift 6.4

## Requirements

- iOS 17 or later
- Xcode 27 with the Swift 6.4 compiler
- A Navidrome/OpenSubsonic server reachable over HTTPS
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or later for generating the Xcode project

## Local build

```sh
brew install xcodegen
sh Scripts/prepare-assets.sh
xcodegen generate
sh Scripts/apply-package-lock.sh
open BuFi.xcodeproj
```

Select your development team in Xcode to install the app on a physical device.

## Unsigned IPA

The `iOS Build` GitHub Actions workflow builds with code signing disabled and
publishes `BuFi-1.0.0-build1-unsigned.ipa` and its SHA-256 checksum as workflow
artifacts. An unsigned IPA cannot be
installed directly on stock iOS; it must be signed by the user or a signing
service before installation.

## Privacy

Server credentials are stored in the system Keychain with
device-only-after-first-unlock protection. BuFi does not contain analytics or
advertising SDKs.

## Open-source policy

XcodeGen is used only to generate the project. BuFi links
[SwiftSonic](https://github.com/CassetteLab/swiftsonic),
[GRDB](https://github.com/groue/GRDB.swift),
[Nuke](https://github.com/kean/Nuke), and the
[Zstandard](https://github.com/facebook/zstd) reference decoder, and bundles
the [Unbounded](https://github.com/google/fonts/tree/main/ofl/unbounded) font. Playback
compatibility and audio-session patterns are adapted from
[Amperfy](https://github.com/BLeeEZ/amperfy). TIDAL iOS SDK, Pocket Casts,
Telegram, and Cassette are architecture references only and are not linked.
Attribution and license details for distributed components are in
`OPEN_SOURCE_NOTICES.md`; the dependency and build decisions are recorded in
`Docs/DEPENDENCY_AND_BUILD_AUDIT.md`. Complete corresponding BuFi source
remains available in this public repository under GPLv3-or-later. The verbatim
license texts for linked third-party packages are bundled with the app and
available from Settings → Open Source & Licenses.

## License

GNU General Public License v3.0 or later
