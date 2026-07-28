# Open-source notices

## BuFi

Copyright © 2026 TAE-OK-11  
Licensed under the GNU General Public License v3.0 or later. See `LICENSE`.

## XcodeGen

XcodeGen is used as a build-time project generator and is not linked into the
application.

- Project: <https://github.com/yonaskolb/XcodeGen>
- License: MIT
- Copyright: Yonas Kolb and contributors

## Amperfy

BuFi adapts selected playback compatibility and audio-session patterns from
Amperfy's GPLv3 source. BuFi is therefore distributed under GPLv3-or-later and
keeps the complete corresponding source available in this repository. No
Amperfy binary or library is linked, so Amperfy is not included in the bundled
linked-dependency license file; its attribution remains here.

- Project: <https://github.com/BLeeEZ/amperfy>
- License: GNU General Public License v3.0
- Copyright: Maximilian Bauer and Amperfy contributors

## SwiftSonic

BuFi links SwiftSonic for salted-token authentication support and authenticated
stream, artwork, and download URL construction.

- Project: <https://github.com/CassetteLab/swiftsonic>
- Version: 0.8.3
- License: MIT
- Copyright: 2026 Mathieu Dubart
- License text: <https://github.com/CassetteLab/swiftsonic/blob/v0.8.3/LICENSE>
- Bundled notice: `BuFi/Resources/ThirdPartyLicenses.txt`

## Nuke

BuFi links the Nuke core product for image request coalescing, downsampling,
background decoding, and bounded memory and disk caching. BuFi does not link
the optional NukeUI product.

- Project: <https://github.com/kean/Nuke>
- Version: 13.0.6
- License: MIT
- Copyright: Alexander Grebenyuk and contributors
- License text: <https://github.com/kean/Nuke/blob/13.0.6/LICENSE>
- Bundled notice: `BuFi/Resources/ThirdPartyLicenses.txt`

## Cassette

Cassette is an architectural reference for service isolation, minimal observed
player state, and offline-first behavior. No Cassette source file is linked or
copied into BuFi. It is therefore not included in the linked-dependency license
text bundled with the binary; its attribution and source-license link remain
here.

- Project: <https://github.com/CassetteLab/cassette>
- License of the currently referenced source: Mozilla Public License 2.0
- Copyright: Mathieu Dubart and contributors
- License text: <https://github.com/CassetteLab/cassette/blob/main/LICENSE>

## Zstandard

BuFi links the reference decoder to safely handle HTTP
`Content-Encoding: zstd` on Foundation versions that do not expand it.

- Project: <https://github.com/facebook/zstd>
- Version: 1.5.7
- License option used by BuFi: BSD 3-Clause
- Copyright: Meta Platforms, Inc. and contributors
- License text: <https://github.com/facebook/zstd/blob/v1.5.7/LICENSE>
- Bundled notice: `BuFi/Resources/ThirdPartyLicenses.txt`
