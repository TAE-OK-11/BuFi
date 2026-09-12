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

## GotaTun

Bufi Tunnel links GotaTun as its standard WireGuard userspace engine. The
dependency is pinned to commit `fdf5e909ffe5e12310b2fe72a5fb82ab17dcd2e8`
and is kept behind Bufi's own C ABI rather than modified in-tree.

- Project: <https://github.com/mullvad/gotatun>
- Version at pinned revision: 0.9.2
- License: Mozilla Public License 2.0
- Copyright: Mullvad VPN AB, Cloudflare, Inc., and contributors
- License text: <https://github.com/mullvad/gotatun/blob/fdf5e909ffe5e12310b2fe72a5fb82ab17dcd2e8/LICENSE>
- Source pin: `RustTunnel/Cargo.toml`

## Mullvad VPN iOS reference integration

The utun descriptor discovery, file-descriptor ownership, and packet-framing
patterns in Bufi Tunnel were adapted from Mullvad VPN's GPLv3 iOS GotaTun
integration. Bufi's implementation is independently scoped to a conventional
single-hop WireGuard client and contains none of Mullvad's service-specific,
post-quantum, obfuscation, or relay logic.

- Project: <https://github.com/mullvad/mullvadvpn-app>
- Reviewed revision: `694e2d8945fb656b5840fca15db8823a470cfc52`
- License: GNU General Public License v3.0

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
- Version: 13.2.0
- License: MIT
- Copyright: Alexander Grebenyuk and contributors
- License text: <https://github.com/kean/Nuke/blob/13.2.0/LICENSE>
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
