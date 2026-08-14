from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}\n--- pattern ---\n{old[:500]}")
    file.write_text(text.replace(old, new, 1))


def insert_before_once(path: str, marker: str, addition: str) -> None:
    replace_once(path, marker, addition + marker)


# Adopt Swift 6.2+'s caller-isolation semantics explicitly. CPU-heavy work that
# really should leave an actor is annotated @concurrent below instead of relying
# on implicit executor switching or ad-hoc detached tasks.
replace_once(
    "project.yml",
    '    SWIFT_TREAT_WARNINGS_AS_ERRORS: YES\n    IPHONEOS_DEPLOYMENT_TARGET: "17.0"\n',
    '    SWIFT_TREAT_WARNINGS_AS_ERRORS: YES\n'
    '    OTHER_SWIFT_FLAGS: "$(inherited) -enable-upcoming-feature NonisolatedNonsendingByDefault"\n'
    '    IPHONEOS_DEPLOYMENT_TARGET: "17.0"\n'
)

# HTTP body decoding is explicit concurrent CPU work. Keep it structured in the
# caller task so cancellation propagates naturally and no detached task can
# outlive the request that owns the bytes.
replace_once(
    "BuFi/Core/HTTPContentDecoder.swift",
    '    private static let maximumDecodedBytes = 64 * 1_024 * 1_024\n\n'
    '    static func decode(_ data: Data, contentEncoding: String?) throws -> Data {\n',
    '    private static let maximumDecodedBytes = 64 * 1_024 * 1_024\n\n'
    '    @concurrent\n'
    '    static func decodeAsync(\n'
    '        _ data: Data,\n'
    '        contentEncoding: String?\n'
    '    ) async throws -> Data {\n'
    '        try Task.checkCancellation()\n'
    '        return try decode(data, contentEncoding: contentEncoding)\n'
    '    }\n\n'
    '    static func decode(_ data: Data, contentEncoding: String?) throws -> Data {\n'
)

replace_once(
    "BuFi/Core/OpenSubsonicClient.swift",
    '''    private func decodeResponseData<Payload: Decodable & Sendable>(
        _ data: Data
    ) async throws -> Payload {
        let task: Task<Payload, Error> = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Self.decodePayload(data)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func decodePayload<Payload: Decodable & Sendable>(
''',
    '''    private func decodeResponseData<Payload: Decodable & Sendable>(
        _ data: Data
    ) async throws -> Payload {
        try await Self.decodePayloadConcurrently(data)
    }

    @concurrent
    private static func decodePayloadConcurrently<Payload: Decodable & Sendable>(
        _ data: Data
    ) async throws -> Payload {
        try Task.checkCancellation()
        return try decodePayload(data)
    }

    private nonisolated static func decodePayload<Payload: Decodable & Sendable>(
'''
)

replace_once(
    "BuFi/Core/OpenSubsonicClient.swift",
    '''            let responseData = response.data
            let decodeTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try JSONDecoder().decode(
                    StatusEnvelope.self,
                    from: responseData
                )
            }
            let envelope = try await withTaskCancellationHandler {
                try await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }
''',
    '''            let envelope = try await Self.decodeStatusEnvelope(response.data)
'''
)

insert_before_once(
    "BuFi/Core/OpenSubsonicClient.swift",
    '    private func coalescedReadResponse(\n',
    '''    @concurrent
    private static func decodeStatusEnvelope(_ data: Data) async throws -> StatusEnvelope {
        try Task.checkCancellation()
        return try JSONDecoder().decode(StatusEnvelope.self, from: data)
    }

'''
)

replace_once(
    "BuFi/Core/OpenSubsonicClient.swift",
    '''        do {
            let decodeTask = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try HTTPContentDecoder.decode(
                    encodedData,
                    contentEncoding: contentEncoding
                )
            }
            let data = try await withTaskCancellationHandler {
                try await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }
            return HTTPResponseData(
''',
    '''        do {
            let data = try await HTTPContentDecoder.decodeAsync(
                encodedData,
                contentEncoding: contentEncoding
            )
            return HTTPResponseData(
'''
)

# Playback transport resolution is pure/sendable work plus calls into actors.
# It should not inherit AudioEngine's MainActor just because the player owns the
# request. AVFoundation objects themselves remain MainActor-owned below.
streaming_support = r'''struct PlaybackResourceRequest: Sendable {
    let song: Song
    let quality: StreamQuality
    let compatibilityFormat: String?
    let allowLocalSource: Bool
}

struct PlaybackResourceDescriptor: Sendable {
    let url: URL
    let mimeType: String?
}

enum PlaybackResourceResolver {
    @concurrent
    static func resolve(
        _ request: PlaybackResourceRequest,
        client: OpenSubsonicClient?
    ) async throws -> PlaybackResourceDescriptor {
        try Task.checkCancellation()
        let song = request.song
        if let value = song.externalStreamURL,
           let url = URL(string: value),
           url.scheme?.lowercased() == "https" {
            return PlaybackResourceDescriptor(
                url: url,
                mimeType: song.contentType
            )
        }
        if request.allowLocalSource,
           request.compatibilityFormat?.lowercased() == "raw",
           let local = await OfflineStore.shared.localURL(for: song) {
            try Task.checkCancellation()
            return PlaybackResourceDescriptor(
                url: local,
                mimeType: sourceMIMEType(for: song)
            )
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let url = try await client.streamURL(
            songID: song.id,
            quality: request.quality,
            compatibilityFormat: request.compatibilityFormat
        )
        try Task.checkCancellation()
        return PlaybackResourceDescriptor(
            url: url,
            mimeType: mimeType(
                for: request.compatibilityFormat,
                sourceSong: song
            )
        )
    }

    private static func mimeType(
        for compatibilityFormat: String?,
        sourceSong song: Song
    ) -> String? {
        switch compatibilityFormat?.lowercased() {
        case "aac": "audio/aac"
        case "mp3": "audio/mpeg"
        case "opus": "audio/ogg; codecs=opus"
        case "raw", nil: sourceMIMEType(for: song)
        default: song.contentType
        }
    }

    private static func sourceMIMEType(for song: Song) -> String? {
        switch song.suffix?.lowercased() {
        case "flac": "audio/flac"
        case "opus": "audio/ogg; codecs=opus"
        case "ogg", "oga": song.contentType ?? "audio/ogg"
        case "mp3": "audio/mpeg"
        case "aac": "audio/aac"
        case "m4a", "m4b", "mp4", "alac": "audio/mp4"
        case "wav", "wave": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        default: song.contentType
        }
    }
}

struct NowPlayingVisualIdentity: Hashable, Sendable {
    let accountScope: String?
    let playbackID: UUID
    let metadataRevision: String
    let artworkRevision: String
}

'''
insert_before_once(
    "BuFi/Playback/AudioEngine.swift",
    '@MainActor\nfinal class AudioEngine: NSObject, ObservableObject {\n',
    streaming_support
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''    private struct PlaybackResource {
        let url: URL
        let mimeType: String?
    }

''',
    ''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''    private var preparedPlaybackWarmupTasks: [PreparedPlaybackKey: Task<Void, Never>] = [:]
''',
    '''    private var preparedPlaybackWarmupTasks: [PreparedPlaybackKey: Task<Void, Never>] = [:]
    private var preparedPlaybackWarmupTokens: [PreparedPlaybackKey: UUID] = [:]
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''    private var nowPlayingVisualKey: String?
    private var nowPlayingArtworkKey: String?
    private var nowPlayingArtworkRequestKey: String?
''',
    '''    private var nowPlayingVisualKey: NowPlayingVisualIdentity?
    private var nowPlayingArtworkKey: NowPlayingVisualIdentity?
    private var nowPlayingArtworkRequestKey: NowPlayingVisualIdentity?
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''    private func playbackResource(
        for song: Song,
        compatibilityFormat: String?,
        allowLocalSource: Bool = true
    ) async throws -> PlaybackResource {
        if let value = song.externalStreamURL,
           let url = URL(string: value),
           url.scheme?.lowercased() == "https" {
            return PlaybackResource(url: url, mimeType: song.contentType)
        }
        // A downloaded source avoids radio use and is attempted once. If the
        // system rejects it, later codec fallbacks bypass the local source.
        if allowLocalSource,
           compatibilityFormat?.lowercased() == "raw",
           let local = await OfflineStore.shared.localURL(for: song) {
            return PlaybackResource(
                url: local,
                mimeType: Self.sourceMIMEType(for: song)
            )
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let url = try await client.streamURL(
            songID: song.id,
            quality: quality,
            compatibilityFormat: compatibilityFormat
        )
        return PlaybackResource(
            url: url,
            mimeType: Self.mimeType(
                for: compatibilityFormat,
                sourceSong: song
            )
        )
    }
''',
    '''    private func playbackResource(
        for song: Song,
        compatibilityFormat: String?,
        allowLocalSource: Bool = true
    ) async throws -> PlaybackResourceDescriptor {
        let request = PlaybackResourceRequest(
            song: song,
            quality: quality,
            compatibilityFormat: compatibilityFormat,
            allowLocalSource: allowLocalSource
        )
        return try await PlaybackResourceResolver.resolve(
            request,
            client: client
        )
    }
'''
)

# The MIME mapping now belongs to the Sendable transport resolver rather than
# AudioEngine's MainActor domain.
replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''    private static func mimeType(
        for compatibilityFormat: String?,
        sourceSong song: Song
    ) -> String? {
        switch compatibilityFormat?.lowercased() {
        case "aac": "audio/aac"
        case "mp3": "audio/mpeg"
        case "opus": "audio/ogg; codecs=opus"
        case "raw", nil: sourceMIMEType(for: song)
        default: song.contentType
        }
    }

    private static func sourceMIMEType(for song: Song) -> String? {
        switch song.suffix?.lowercased() {
        case "flac": "audio/flac"
        case "opus": "audio/ogg; codecs=opus"
        case "ogg", "oga": song.contentType ?? "audio/ogg"
        case "mp3": "audio/mpeg"
        case "aac": "audio/aac"
        case "m4a", "m4b", "mp4", "alac": "audio/mp4"
        case "wav", "wave": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        default: song.contentType
        }
    }

''',
    ''
)

# Warmup cleanup is token-gated. An old cancelled task may finish after a new
# warmup for the same key has started; it must never erase the replacement.
old_prepare_start = '''        guard preparedPlaybackWarmupTasks[key] == nil else {
            return
        }

        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
'''
new_prepare_start = '''        guard preparedPlaybackWarmupTasks[key] == nil else {
            return
        }

        let warmupToken = UUID()
        preparedPlaybackWarmupTokens[key] = warmupToken
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                guard self.preparedPlaybackWarmupTokens[key] == warmupToken else {
                    return
                }
                self.preparedPlaybackWarmupTokens[key] = nil
                self.preparedPlaybackWarmupTasks[key] = nil
            }
            do {
'''
replace_once("BuFi/Playback/AudioEngine.swift", old_prepare_start, new_prepare_start)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''                      }) else {
                    self.preparedPlaybackWarmupTasks[key] = nil
                    return
                }
''',
    '''                      }) else {
                    return
                }
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''            } catch {
                // Warming is speculative. Active playback retains its normal
                // codec fallback and recovery path if preparation fails.
            }
            self.preparedPlaybackWarmupTasks[key] = nil
        }
        preparedPlaybackWarmupTasks[key] = task
''',
    '''            } catch {
                // Warming is speculative. Active playback retains its normal
                // codec fallback and recovery path if preparation fails.
            }
        }
        preparedPlaybackWarmupTasks[key] = task
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''        preparedPlaybackWarmupTasks[prepared.key] = nil
    }

    private func invalidateStagedSuccessor''',
    '''        preparedPlaybackWarmupTokens[prepared.key] = nil
        preparedPlaybackWarmupTasks[prepared.key] = nil
    }

    private func invalidateStagedSuccessor'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''            preparedPlaybackAssets[evicted] = nil
            preparedPlaybackWarmupTasks.removeValue(forKey: evicted)?.cancel()
''',
    '''            preparedPlaybackAssets[evicted] = nil
            preparedPlaybackWarmupTokens[evicted] = nil
            preparedPlaybackWarmupTasks.removeValue(forKey: evicted)?.cancel()
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''        preparedPlaybackWarmupTasks[key] = nil
        return prepared
''',
    '''        preparedPlaybackWarmupTokens[key] = nil
        preparedPlaybackWarmupTasks[key] = nil
        return prepared
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''        preparedPlaybackWarmupTasks.values.forEach { $0.cancel() }
        preparedPlaybackWarmupTasks.removeAll(keepingCapacity: false)
        preparedPlaybackAssets.removeAll(keepingCapacity: false)
''',
    '''        preparedPlaybackWarmupTasks.values.forEach { $0.cancel() }
        preparedPlaybackWarmupTasks.removeAll(keepingCapacity: false)
        preparedPlaybackWarmupTokens.removeAll(keepingCapacity: false)
        preparedPlaybackAssets.removeAll(keepingCapacity: false)
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''        let visualKey = [
            playbackItem.accountScope ?? "",
            playbackItem.id.uuidString,
            playbackItem.metadataRevision,
            playbackItem.artwork.revision
        ].joined(separator: "|")
''',
    '''        let visualKey = NowPlayingVisualIdentity(
            accountScope: playbackItem.accountScope,
            playbackID: playbackItem.id,
            metadataRevision: playbackItem.metadataRevision,
            artworkRevision: playbackItem.artwork.revision
        )
'''
)

# Regression tests cover typed visual identity and the explicit @concurrent
# decode boundary. These are intentionally pure and deterministic.
Path("BuFiTests/SwiftConcurrencyArchitectureTests.swift").write_text(r'''import Foundation
import XCTest
@testable import BuFi

final class SwiftConcurrencyArchitectureTests: XCTestCase {
    func testNowPlayingVisualIdentityKeepsFieldsStructurallyDistinct() {
        let playbackID = UUID()
        let lhs = NowPlayingVisualIdentity(
            accountScope: "account|segment",
            playbackID: playbackID,
            metadataRevision: "meta",
            artworkRevision: "art"
        )
        let rhs = NowPlayingVisualIdentity(
            accountScope: "account",
            playbackID: playbackID,
            metadataRevision: "segment|meta",
            artworkRevision: "art"
        )

        XCTAssertNotEqual(lhs, rhs)
    }

    func testConcurrentContentDecoderPassesThroughPlainData() async throws {
        let input = Data("swift-6.4".utf8)
        let output = try await HTTPContentDecoder.decodeAsync(
            input,
            contentEncoding: nil
        )
        XCTAssertEqual(output, input)
    }
}
''')

# The migration intentionally removes ad-hoc detached CPU tasks from the core.
for path in ["BuFi/Core/OpenSubsonicClient.swift", "BuFi/Core/HTTPContentDecoder.swift"]:
    if "Task.detached" in Path(path).read_text():
        raise SystemExit(f"{path}: Task.detached remains after migration")

print("Swift 6.4 streaming/core refactor applied")
