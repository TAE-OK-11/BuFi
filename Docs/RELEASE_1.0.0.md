# BuFi 1.0.0 (build 1)

BuFi 1.0 is the first public-service readiness release. It keeps the existing
Classic, Liquid Glass, Dynamic player, and full-lyrics visual design while
rebuilding expensive derived work and failure handling around bounded,
cancellable services.

## Player and lyrics

- Keeps native `AVPlayer`, background audio, AirPlay, Now Playing, queue,
  scrobbling, and automatic original/AAC 256 quality routing.
- Owns item, timeline, route, interruption, and media-reset observations for
  their exact lifetimes so rapid track changes cannot leave duplicate work.
- Uses low-cost periodic timeline updates for the seek bar and precise boundary
  updates for synchronized lyrics, with immediate correction after seeks and
  recovery.
- Preserves the compact and full lyric designs while clipping long content to
  the intended viewport and animating only the changing lyric row.

## Artwork Palette Engine V3

- Samples each decoded artwork once and performs deterministic perceptual
  clustering in OKLab.
- Uses population, chroma, lightness, alpha, and artwork-relative position to
  form a stable palette without inventing colors absent from the cover.
- Treats black, white, and gray artwork as intentional when neutral pixels make
  up at least 85 percent of the image; colorful covers still reject dominant
  extreme neutrals that would hide their useful colors.
- Renders static, spatial multicolor fields that follow the cover composition.
  Bright mode lifts the extracted colors rather than changing the whole player
  into a light appearance. Default remains a single derived color in Classic
  and Liquid Glass.
- Coalesces simultaneous palette work and stores versioned, account-scoped,
  bounded palette rows in GRDB.

## Networking, persistence, and energy

- Retries only safe read-only OpenSubsonic requests with a two-retry jittered
  budget for transient transport, 408, 429, and 5xx failures.
- Coalesces identical detail and lyric work, rejects stale generations, and
  bounds speculative activity on constrained networks, Low Power Mode, and
  elevated thermal pressure.
- Keeps credentials in Apple Keychain and structured history/cache state in
  transactional GRDB storage.
- Avoids continuous background palette animation, redundant image scans,
  oversized artwork decoding, broad view animations, and unnecessary progress
  publication.

## UI and account safety

- Applies one safe-area/content-clearance policy to Home, Search, Library,
  Settings, album/playlist details, personalized mixes, and license screens so
  the persistent mini player does not cover the final rows.
- Shows the sanitized connected server domain instead of a hard-coded service
  name and never displays credentials or query data.
- Uses an Apple Settings-style destructive logout action with confirmation and
  ordered cancellation, persistence, cache, Keychain, and audio cleanup.

## Compatibility and verification

- iOS 17 minimum; Swift 5 language mode with complete concurrency checking.
- Required clean Release build, unit tests, and simulator launch smoke test on
  Xcode 26.6; advisory Release build on the Xcode 27 preview runner.
- Monolithic LLVM LTO, whole-module Swift optimization, dead-code stripping,
  dSYM output, package pinning, and the safe non-global stripping workaround
  retained for iOS 27 beta device stability.
- Physical launch/playback checks on both iOS 17 and iOS 27 beta are required
  before distribution because hosted CI cannot replace real-device validation.

## Open source

The app exposes BuFi's GPLv3-or-later notice and the required notices for
SwiftSonic, GRDB, Nuke, Zstandard, and the Unbounded font. Amperfy attribution
is retained for adapted GPL compatibility/audio-session patterns. TIDAL SDK,
Cassette, and XcodeGen are development references or build tools and are not
presented as linked runtime components.
