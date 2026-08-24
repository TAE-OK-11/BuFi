# BuFi Liquid Glass app icon

The unmasked 1024 x 1024 foreground artwork is split into two files for Apple Icon Composer. The checked-in asset-catalog icon is the build-compatible flattened version.

## Icon Composer setup

1. Create an iOS-only document named `AppIcon`.
2. Set the background to solid `#F9FBFF`.
3. Import `01-stream-wave.svg`, then `02-orbit.svg` in that order so the orbit cleans up the two joins.
4. Keep the source position and scale unchanged.
5. Let Icon Composer provide highlights, refraction, and shadows; don't add static versions of those effects to the SVG.
6. Preview Default, Dark, Clear, and Tinted/Mono appearances before adding `AppIcon.icon` to Xcode.

The mark uses only an orbit and one tapered streaming wave, so it remains recognizable at small sizes and behaves predictably across appearance modes. The square sources have no rounded-corner mask because Apple platforms apply the final enclosure.
