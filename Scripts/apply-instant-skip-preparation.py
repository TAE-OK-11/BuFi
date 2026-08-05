from pathlib import Path

path = Path("BuFi/Playback/AudioEngine.swift")
text = path.read_text()

replacements = []

replacements.append((
'''        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "stream-quality")
            guard oldValue != quality, currentSong != nil else { return }
            restartPlaybackPlan(resumeFrom: elapsed)
        }
''',
'''        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "stream-quality")
            guard oldValue != quality, currentSong != nil else { return }
            discardPreparedPlaybackAssets()
            restartPlaybackPlan(resumeFrom: elapsed)
        }
'''))

replacements.append((
'''    private struct PlaybackResource {
        let url: URL
        let mimeType: String?
    }
''',
'''    private struct PlaybackResource {
        let url: URL
        let mimeType: String?
    }

    private struct PreparedPlaybackAsset {
        let key: String
        let songID: String
        let compatibilityFormat: String
        let mimeType: String?
        let asset: AVURLAsset
    }
'''))

replacements.append((
'''    private var offlinePrefetchTask: Task<Void, Never>?
    private var networkPrefetchTask: Task<Void, Never>?
    private var autoplayTask: Task<Void, Never>?
''',
'''    private var offlinePrefetchTask: Task<Void, Never>?
    private var networkPrefetchTask: Task<Void, Never>?
    private var preparedPlaybackAssets: [String: PreparedPlaybackAsset] = [:]
    private var preparedPlaybackAssetOrder: [String] = []
    private var preparedPlaybackWarmupTasks: [String: Task<Void, Never>] = [:]
    private var autoplayTask: Task<Void, Never>?
'''))

replacements.append((
'''            networkPrefetchTask?.cancel()
            networkPrefetchTask = nil
            cancelPlaybackRecovery()
''',
'''            networkPrefetchTask?.cancel()
            networkPrefetchTask = nil
            discardPreparedPlaybackAssets()
            cancelPlaybackRecovery()
'''))

replacements.append((
'''        networkPrefetchTask?.cancel()
        networkPrefetchTask = nil
        if let client {
''',
'''        networkPrefetchTask?.cancel()
        networkPrefetchTask = nil
        discardPreparedPlaybackAssets()
        if let client {
'''))

replacements.append((
'''        networkPrefetchTask?.cancel()
        networkPrefetchTask = nil
    }

    private func pausePlayback''',
'''        networkPrefetchTask?.cancel()
        networkPrefetchTask = nil
        discardPreparedPlaybackAssets()
    }

    private func pausePlayback'''))

replacements.append((
'''    private func playbackResource(
        for song: Song,
        compatibilityFormat: String?
    ) async throws -> PlaybackResource {
''',
'''    private func playbackResource(
        for song: Song,
        compatibilityFormat: String?,
        allowLocalSource: Bool = true
    ) async throws -> PlaybackResource {
'''))

replacements.append((
'''        if fallbackIndex == 0,
           compatibilityFormat?.lowercased() == "raw",
''',
'''        if allowLocalSource,
           compatibilityFormat?.lowercased() == "raw",
'''))

marker = '''    private func scheduleNetworkPrefetch() {
'''
insert = '''    private static let preparedPlaybackAssetLimit = 3

    private static func preparedPlaybackKey(
        songID: String,
        quality: StreamQuality,
        compatibilityFormat: String
    ) -> String {
        [songID, quality.rawValue, compatibilityFormat.lowercased()]
            .joined(separator: "|")
    }

    private static func makeURLAsset(
        url: URL,
        mimeType: String?
    ) -> AVURLAsset {
        // Some OpenSubsonic servers omit or generalize Content-Type. Preserve
        // the same out-of-band hint used by active playback while warming the
        // exact asset that will later be handed to AVPlayer.
        let options: [String: Any] = mimeType.map {
            ["AVURLAssetOutOfBandMIMETypeKey": $0]
        } ?? [:]
        return AVURLAsset(url: url, options: options)
    }

    private func preparePlaybackAsset(for song: Song) {
        guard song.externalStreamURL == nil else { return }
        let preparedQuality = quality
        let compatibilityFormat = Self.initialCompatibilityFormat(
            for: preparedQuality,
            song: song
        )
        let key = Self.preparedPlaybackKey(
            songID: song.id,
            quality: preparedQuality,
            compatibilityFormat: compatibilityFormat
        )
        guard preparedPlaybackAssets[key] == nil,
              preparedPlaybackWarmupTasks[key] == nil else {
            return
        }

        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let resource = try await self.playbackResource(
                    for: song,
                    compatibilityFormat: compatibilityFormat,
                    allowLocalSource: true
                )
                guard !Task.isCancelled,
                      self.quality == preparedQuality,
                      self.queue.contains(where: { $0.id == song.id }) else {
                    self.preparedPlaybackWarmupTasks[key] = nil
                    return
                }

                let asset = Self.makeURLAsset(
                    url: resource.url,
                    mimeType: resource.mimeType
                )
                self.storePreparedPlaybackAsset(
                    PreparedPlaybackAsset(
                        key: key,
                        songID: song.id,
                        compatibilityFormat: compatibilityFormat,
                        mimeType: resource.mimeType,
                        asset: asset
                    )
                )

                do {
                    // This opens the transport, validates the stream response,
                    // and loads enough AVFoundation metadata that a skip can
                    // reuse the same asset during the page transition.
                    _ = try await asset.load(.isPlayable)
                } catch {
                    if self.preparedPlaybackAssets[key]?.asset === asset {
                        self.preparedPlaybackAssets[key] = nil
                        self.preparedPlaybackAssetOrder.removeAll { $0 == key }
                    }
                }
            } catch {
                // Warming is speculative. Active playback retains its normal
                // codec fallback and recovery path if preparation fails.
            }
            self.preparedPlaybackWarmupTasks[key] = nil
        }
        preparedPlaybackWarmupTasks[key] = task
    }

    private func storePreparedPlaybackAsset(_ prepared: PreparedPlaybackAsset) {
        preparedPlaybackAssets[prepared.key] = prepared
        preparedPlaybackAssetOrder.removeAll { $0 == prepared.key }
        preparedPlaybackAssetOrder.append(prepared.key)
        while preparedPlaybackAssetOrder.count > Self.preparedPlaybackAssetLimit {
            let evicted = preparedPlaybackAssetOrder.removeFirst()
            preparedPlaybackAssets[evicted] = nil
            preparedPlaybackWarmupTasks.removeValue(forKey: evicted)?.cancel()
        }
    }

    private func takePreparedPlaybackAsset(
        for song: Song,
        compatibilityFormat: String?
    ) -> PreparedPlaybackAsset? {
        guard let compatibilityFormat else { return nil }
        let key = Self.preparedPlaybackKey(
            songID: song.id,
            quality: quality,
            compatibilityFormat: compatibilityFormat
        )
        guard let prepared = preparedPlaybackAssets.removeValue(forKey: key),
              prepared.songID == song.id,
              prepared.compatibilityFormat == compatibilityFormat else {
            return nil
        }
        preparedPlaybackAssetOrder.removeAll { $0 == key }
        // Do not cancel an in-progress AVAsset warmup after handing that same
        // asset to the active player. Dropping our task handle lets it finish
        // while AVPlayer immediately consumes the partially warmed resource.
        preparedPlaybackWarmupTasks[key] = nil
        return prepared
    }

    private func discardPreparedPlaybackAssets() {
        preparedPlaybackWarmupTasks.values.forEach { $0.cancel() }
        preparedPlaybackWarmupTasks.removeAll(keepingCapacity: false)
        preparedPlaybackAssets.removeAll(keepingCapacity: false)
        preparedPlaybackAssetOrder.removeAll(keepingCapacity: false)
    }

'''
if marker not in text:
    raise SystemExit("scheduleNetworkPrefetch marker missing")
text = text.replace(marker, insert + marker, 1)

replacements.append((
'''        guard !upcoming.isEmpty else {
            networkPrefetchTask = nil
            return
        }

        networkPrefetchTask = Task(priority: .utility) { [weak self] in
''',
'''        guard !upcoming.isEmpty else {
            networkPrefetchTask = nil
            return
        }

        // Prepare the actual AVURLAsset in addition to lyrics and artwork.
        // The player consumes this same object on skip, so work completed while
        // the current song is playing is not discarded or repeated.
        for song in upcoming {
            preparePlaybackAsset(for: song)
        }

        networkPrefetchTask = Task(priority: .utility) { [weak self] in
'''))

replacements.append((
'''        activeCompatibilityFormat = compatibilityFormat
        isBuffering = wantsPlayback
        itemLoadTask = Task { [weak self] in
''',
'''        activeCompatibilityFormat = compatibilityFormat
        isBuffering = wantsPlayback

        if let prepared = takePreparedPlaybackAsset(
            for: song,
            compatibilityFormat: compatibilityFormat
        ) {
            replacePlayerItem(
                asset: prepared.asset,
                mimeType: prepared.mimeType,
                resumePosition: resumePosition
            )
            return
        }

        itemLoadTask = Task { [weak self] in
'''))

replacements.append((
'''                let resource = try await self.playbackResource(
                    for: song,
                    compatibilityFormat: compatibilityFormat
                )
''',
'''                let resource = try await self.playbackResource(
                    for: song,
                    compatibilityFormat: compatibilityFormat,
                    allowLocalSource: self.fallbackIndex == 0
                )
'''))

old_replace = '''    private func replacePlayerItem(
        url: URL,
        mimeType: String?,
        resumePosition: TimeInterval
    ) {
        cancelPlaybackRecovery()
        // Amperfy uses an out-of-band MIME hint before handing Subsonic
        // streams to its player. Some servers omit or generalize Content-Type,
        // so applying the same GPLv3-covered compatibility pattern keeps
        // Core AVFoundation from rejecting an otherwise valid audio stream.
        let options: [String: Any] = mimeType.map {
            ["AVURLAssetOutOfBandMIMETypeKey": $0]
        } ?? [:]
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
'''
new_replace = '''    private func replacePlayerItem(
        url: URL,
        mimeType: String?,
        resumePosition: TimeInterval
    ) {
        replacePlayerItem(
            asset: Self.makeURLAsset(url: url, mimeType: mimeType),
            mimeType: mimeType,
            resumePosition: resumePosition
        )
    }

    private func replacePlayerItem(
        asset: AVURLAsset,
        mimeType: String?,
        resumePosition: TimeInterval
    ) {
        cancelPlaybackRecovery()
        let item = AVPlayerItem(asset: asset)
'''
replacements.append((old_replace, new_replace))

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected one match, found {count}: {old[:100]!r}")
    text = text.replace(old, new, 1)

path.write_text(text)

# Document the active-stream warmup behavior.
docs = Path("Docs/NETWORKING.md")
doc_text = docs.read_text()
doc_old = '''- Structured lyrics are retained for up to six hours and the next two queued
  tracks have lyrics and 360 px artwork warmed opportunistically. Low Power
  Mode, serious thermal pressure, logout, and memory warnings cancel or trim
  speculative work immediately.
'''
doc_new = '''- Structured lyrics are retained for up to six hours and the next two queued
  tracks have lyrics, 360 px artwork, authenticated stream URLs, and reusable
  `AVURLAsset` metadata warmed opportunistically. A manual skip consumes the
  same partially or fully prepared asset while the page animation runs instead
  of opening a duplicate request. Low Power Mode, serious thermal pressure,
  logout, and memory warnings cancel or trim speculative work immediately.
'''
if doc_text.count(doc_old) != 1:
    raise SystemExit("networking documentation marker missing")
docs.write_text(doc_text.replace(doc_old, doc_new, 1))

readme = Path("README.md")
readme_text = readme.read_text()
readme_old = "- In-flight API request coalescing, bounded response reuse, and energy-aware next-track lyric/artwork prefetching\n"
readme_new = "- In-flight API request coalescing, bounded response reuse, and energy-aware next-track lyric/artwork/AVURLAsset preparation for instant skips\n"
if readme_text.count(readme_old) != 1:
    raise SystemExit("README networking marker missing")
readme.write_text(readme_text.replace(readme_old, readme_new, 1))
