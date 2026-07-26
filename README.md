# BuFi

BuFi is a native SwiftUI music client for Navidrome and OpenSubsonic servers.
It is designed around the iOS media stack rather than a web view.

## Current features

- Token-authenticated OpenSubsonic connection with credentials stored in Keychain
- Home, search, albums, artists, playlists, starred music, and server diagnostics
- Native `AVPlayer` playback with a persistent queue, shuffle, repeat, seeking, AirPlay, scrobbling, and background recovery
- Control Center, Lock Screen, Dynamic Island, wired-headset, and Bluetooth media controls through `MPNowPlayingSession`
- Automatic AAC/MP3 compatibility fallback when an original file cannot be decoded
- Built-in speaker/route/interruption recovery and Subsonic MIME compatibility handling adapted from Amperfy
- Synchronized OpenSubsonic lyrics with a full-screen lyrics view
- Apple Music-led visual system with Spotify density, a subtle Deezer accent, and native Liquid Glass on iOS 26+
- Core Graphics dominant-color clustering and an adaptive player background
- Actor-backed artwork caching and downsampling
- HTTP/3-capable API requests plus gzip, Brotli, and bounded Zstandard response decoding
- Korean (default), English, and Japanese localization
- Favorite songs, albums, and artists, with favorite artists pinned above an indexed artist library
- Offline downloads stored in Application Support
- GitHub Actions generation of an unsigned IPA plus an Xcode 27/iOS 27 compatibility build

## Requirements

- iOS 17 or later
- Xcode 26 or later (the CI compatibility job also validates Xcode 27 beta)
- A Navidrome/OpenSubsonic server reachable over HTTPS
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for generating the Xcode project

## Local build

```sh
brew install xcodegen
sh Scripts/prepare-assets.sh
xcodegen generate
open BuFi.xcodeproj
```

Select your development team in Xcode to install the app on a physical device.

## Unsigned IPA

The `iOS Build` GitHub Actions workflow builds with code signing disabled and
publishes `BuFi-unsigned.ipa` as a workflow artifact. An unsigned IPA cannot be
installed directly on stock iOS; it must be signed by the user or a signing
service before installation.

## Privacy

Server credentials are stored in the system Keychain with
device-only-after-first-unlock protection. BuFi does not contain analytics or
advertising SDKs.

## Open-source policy

XcodeGen is used only to generate the project. Playback compatibility and
audio-session patterns are adapted from
[Amperfy](https://github.com/BLeeEZ/amperfy). BuFi also links the
[Zstandard](https://github.com/facebook/zstd) reference decoder. Attribution
and license details are in `OPEN_SOURCE_NOTICES.md`, and complete corresponding
source remains available in this public repository under GPLv3-or-later.

## License

GNU General Public License v3.0 or later
