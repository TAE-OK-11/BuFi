# Dependency and build audit

Audit date: 2026-08-13

## Decisions

| Project | License | BuFi decision |
| --- | --- | --- |
| [SwiftSonic 0.9.0](https://github.com/CassetteLab/swiftsonic) | MIT | Keep and pin. It is a dependency-free, actor-based OpenSubsonic client, and BuFi uses it for authenticated media URLs. |
| [GRDB.swift 7.11.1](https://github.com/groue/GRDB.swift) | MIT | Keep and pin. It supplies the transactional SQLite persistence layer and requires Swift 6.1 or later. |
| [Nuke 13.0.6](https://github.com/kean/Nuke/releases/tag/13.0.6) | MIT | Keep and pin the `Nuke` core product. Remove the unused `NukeUI` product to reduce the build and link graph. |
| [Zstandard 1.5.7](https://github.com/facebook/zstd/releases/tag/v1.5.7) | BSD 3-Clause | Keep and pin. It provides the `libzstd` SwiftPM product used by BuFi's bounded HTTP content decoder. |
| [Amperfy](https://github.com/BLeeEZ/amperfy) | GPLv3 | Continue using selected compatibility and audio-session patterns with attribution. Do not add the complete app as a package. |
| [Cassette](https://github.com/CassetteLab/cassette) | MPL-2.0 for current source | Continue as an architectural reference only. It is an application, not a reusable package required by BuFi. |
| [TIDAL iOS SDK](https://github.com/tidal-music/tidal-sdk-ios) | Apache-2.0 | Architecture reference only at revision `41aed3a`. Adopt bounded task scheduling, keyed in-flight request coalescing, jittered retry, and observer ownership patterns without linking or copying the SDK. |

The linked packages fit BuFi's iOS 17 floor: SwiftSonic supports iOS 16, GRDB
supports iOS 13, Nuke 13 supports iOS 15, and zstd's manifest supports iOS 9.
Cassette currently requires iOS 18 and is therefore not a suitable source-level
dependency for BuFi's supported range.

No additional playback framework was added. Replacing the working AVPlayer-based
engine with Cassette's AudioStreaming stack would be a high-risk architectural
migration, not a stabilization change. BuFi already has native format routing,
background playback, route recovery, and compatibility fallback paths.

## Reproducibility

The four linked packages use `exactVersion` constraints in `project.yml` and
their exact Git revisions are recorded in the repository-level
`Package.resolved`. After XcodeGen creates the project,
`Scripts/apply-package-lock.sh` installs that lock into the generated workspace
before dependency resolution. This prevents a moved tag from silently changing
a local or CI build. Updates must change both files deliberately and pass both
toolchain jobs.

## Distribution notices

`BuFi/Resources/ThirdPartyLicenses.txt` bundles the verbatim license files from
the pinned SwiftSonic 0.9.0, GRDB.swift 7.11.1, Nuke 13.0.6, and Zstandard
1.5.7 tags, plus the SIL Open Font License for the bundled Unbounded font. The
open-source settings screen opens this resource inside the app, satisfying the
linked packages' requirement to reproduce their copyright, permission,
condition, and disclaimer text with a binary distribution.

Cassette remains an architectural reference with no linked or copied source,
and Amperfy is not linked as a third-party binary. Their attribution and
official license links remain in `OPEN_SOURCE_NOTICES.md`; they are intentionally
outside the bundled linked-dependency license file. Amperfy-related GPL
obligations are handled by BuFi's GPLv3-or-later distribution and corresponding
public source. XcodeGen is also excluded from the app bundle because it is only
a build-time project generator.

## Swift and release settings

- The project requires the current stable
  [XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0).
  It uses the documented `xcode16_3` project format (already present in the
  [2.45.4 ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/ProjectSpec.md))
  while recording Xcode 26.6 as the last-upgrade version. Xcode 27 can open and
  build this format without a source migration.
- The BuFi app and test targets use `SWIFT_VERSION = 6.0` with
  `SWIFT_STRICT_CONCURRENCY = complete`. CI verifies both settings for Debug and
  Release before compiling, testing, or packaging either target.
- The iOS 27 beta playback crash was isolated to a `MPMediaItemArtwork` callback
  inheriting main-actor isolation while MediaPlayer invoked it on its private
  access queue. The callback now has an explicit Sendable boundary and the
  exact Swift 6 build passes the Xcode 26.6 test/launch job and Xcode 27/iOS 27
  Release launch job.
- Swift warnings are treated as errors for BuFi-owned targets so new migration
  regressions cannot silently enter CI.
- Release retains speed optimization, whole-module compilation, documented
  LLVM link-time optimization, dead-code stripping, dSYMs, disabled assertions,
  and disabled testability. `-Ounchecked` is
  intentionally not used because removing overflow and runtime safety checks is
  unsuitable for a stabilization build.
- Xcode 26.3 through 27 beta can corrupt dyld chained fixups when Archive runs
  `strip -S -T` on some Swift 6 binaries (FB23528109), producing a device-only
  crash before `main()`. BuFi therefore keeps LTO and dead-code stripping but
  uses `STRIP_STYLE = non-global` and `STRIP_SWIFT_SYMBOLS = NO`. CI also passes
  both values as command-line overrides so SwiftPM product targets inherit the
  workaround.
- The undocumented user-defined `SWIFT_LTO` setting and the C-only
  `GCC_OPTIMIZATION_LEVEL` override were removed. The app target is Swift, while
  the zstd C target is owned by SwiftPM.
- Release asset catalogs optimize for space.

Apple documents these settings in the
[Xcode build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference)
and recommends enabling complete concurrency checking before moving a target to
Swift 6 in
[Updating an app to use strict concurrency](https://developer.apple.com/documentation/swift/updating-an-app-to-use-strict-concurrency).

## CI toolchain policy

- The required build uses GitHub's `macos-26` Arm64 runner and Xcode 26.6.
- The Xcode 27 beta build uses GitHub's official `xcode-27` preview label. It is
  advisory because GitHub explicitly warns that preview software and capacity
  can be unstable.
- Xcode 27 logs are uploaded on every run to retain new SDK and compiler
  warnings.
- CI keeps a toolchain-specific Swift Package clone cache, disables the unused
  compiler index store, explicitly parallelizes targets, and emits Xcode's
  build-timing summary. DerivedData is intentionally not cached so verification
  remains a clean Release build.
- Pull requests run only the verification workflow; the artifact workflow runs
  after changes reach `main`, avoiding duplicate builds.
- CI compiles the unsigned Release IPA and launches the Debug simulator app
  once. It does not compile or run the unit-test bundle on every build.
  Physical iOS 17 and iOS 27 beta devices remain release gates.

Runner availability and installed toolchains are verified against GitHub's
[macOS 26 image manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md),
[Xcode 27 image manifest](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-Readme.md),
and [Xcode 27 public preview announcement](https://github.com/actions/runner-images/issues/14404).

## Privacy manifest

`BuFi/Resources/PrivacyInfo.xcprivacy` declares that BuFi does not track users
and contains no tracking-domain list. It reports the app's use of its own
`UserDefaults` container with Apple's `CA92.1` approved reason. Credentials
remain in Keychain and no analytics or advertising SDK is present. Any future
required-reason API or data collection must update this manifest and the App
Store privacy answers in the same release.

## Energy note

There is no build flag that by itself guarantees lower battery use. Apple's
guidance is to reduce work, redraws, networking, and optional activity, then
measure on a physical device with Power Profiler. Build optimization complements
those runtime changes but does not replace measurement. See
[Reducing your app's battery use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-battery-use)
and
[Analyzing your app's battery use](https://developer.apple.com/documentation/xcode/analyzing-your-app-s-battery-use).

## Runtime and dead-code audit

- Album/playlist rows previously recomputed two sets and scanned the entire
  queue inside every row render. The collection layout is now classified once
  per detail render and each fallback track number is supplied by the parent,
  removing the O(n²) path.
- Expired detail responses previously stayed resident until logout. Album,
  playlist, and artist caches now discard expired entries and enforce bounded
  per-type limits.
- Redundant temporary arrays were removed from static category, album-prefix,
  and player artwork iteration where stable collection indices are available.
- The `AudioEngine` singleton's destructor was unreachable during the app
  lifetime and produced Swift 6 isolation warnings. It was removed, while
  per-item end notifications now share the same explicit lifecycle as stall and
  failure observers.
- No complete view or OpenSubsonic response model was removed: the apparently
  legacy mini player is still mounted by `RootView`, and low-reference payload
  types are instantiated indirectly by `Decodable`. Removing either category
  would be a functional regression rather than dead-code cleanup.
