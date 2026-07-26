# BuFi

BuFi is a native SwiftUI music client for Navidrome and OpenSubsonic servers.
It is designed around the iOS media stack rather than a web view.

## Current features

- Token-authenticated OpenSubsonic connection with credentials stored in Keychain
- Home, search, albums, artists, playlists, starred music, and server diagnostics
- Native `AVPlayer` playback with queue, shuffle, repeat, seeking, AirPlay, lock-screen controls, and scrobbling
- Automatic AAC/MP3 compatibility fallback when an original file cannot be decoded
- Synchronized OpenSubsonic lyrics with a full-screen lyrics view
- Core Graphics dominant-color clustering and an adaptive player background
- Actor-backed artwork caching and downsampling
- Offline downloads stored in Application Support
- GitHub Actions generation of an unsigned IPA on every push

## Requirements

- iOS 17 or later
- Xcode 16 or later
- A Navidrome/OpenSubsonic server reachable over HTTPS
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for generating the Xcode project

## Local build

```sh
brew install xcodegen
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

The server URL and username are stored as preferences. Passwords are stored in
the system Keychain. BuFi does not contain analytics, advertising SDKs, or
third-party runtime dependencies.

## Open-source policy

BuFi currently ships without third-party runtime dependencies. XcodeGen is used
only to generate the Xcode project and is available under the MIT License.

[Amperfy](https://github.com/BLeeEZ/amperfy) (GPLv3) was evaluated as a
compatibility and feature reference. No Amperfy source code is copied or linked
into BuFi, so BuFi remains independently implemented under the MIT License. If
GPL-covered source is incorporated later, BuFi's distribution license and
source-availability obligations must be updated before publishing binaries.

## License

MIT
