# Open-source notices

## BuFi

Copyright © 2026 TAE-OK-11  
Licensed under the GNU General Public License v3.0 or later. See `LICENSE`.

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
- Version: 0.9.0
- License: MIT
- Copyright: 2026 Mathieu Dubart
- License text: <https://github.com/CassetteLab/swiftsonic/blob/v0.9.0/LICENSE>
- Bundled notice: `BuFi/Resources/ThirdPartyLicenses.txt`

## GRDB.swift

BuFi links GRDB for transactional, actor-isolated playback history, offline
metadata, home-cache, and play-queue persistence.

- Project: <https://github.com/groue/GRDB.swift>
- Version: 7.11.1
- License: MIT
- Copyright: 2015-2025 Gwendal Roué
- License text: <https://github.com/groue/GRDB.swift/blob/v7.11.1/LICENSE>
- Bundled notice: `BuFi/Resources/ThirdPartyLicenses.txt`

## Nuke

BuFi links the Nuke core product for image request coalescing, downsampling,
background decoding, and bounded memory and disk caching. BuFi does not link
the optional NukeUI product.

- Project: <https://github.com/kean/Nuke>
- Version: 13.1.0
- License: MIT
- Copyright: Alexander Grebenyuk and contributors
- License text: <https://github.com/kean/Nuke/blob/13.1.0/LICENSE>
- Bundled notice: `BuFi/Resources/ThirdPartyLicenses.txt`

## Zstandard

BuFi links the reference decoder to safely handle HTTP
`Content-Encoding: zstd` on Foundation versions that do not expand it.

- Project: <https://github.com/facebook/zstd>
- Version: 1.5.7
- License option used by BuFi: BSD 3-Clause
- Copyright: Meta Platforms, Inc. and contributors
- License text: <https://github.com/facebook/zstd/blob/v1.5.7/LICENSE>
- Bundled notice: `BuFi/Resources/ThirdPartyLicenses.txt`

## Unbounded

BuFi bundles the Unbounded variable font for playlist-cover typography.

- Project: <https://github.com/google/fonts/tree/main/ofl/unbounded>
- Pinned source revision: `8b80d4f3f73cfe02b69a6f0dc71da5a1cc574bd3`
- License: SIL Open Font License 1.1
- Copyright: The Unbounded Project Authors
- Bundled notice: `BuFi/Resources/ThirdPartyLicenses.txt`
