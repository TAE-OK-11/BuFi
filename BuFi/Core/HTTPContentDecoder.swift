import Foundation
import libzstd

enum HTTPContentDecoder {
    private static let zstandardMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    private static let maximumDecodedBytes = 64 * 1_024 * 1_024

    @concurrent
    static func decodeAsync(
        _ data: Data,
        contentEncoding: String?
    ) async throws -> Data {
        try Task.checkCancellation()
        return try decode(data, contentEncoding: contentEncoding)
    }

    static func requiresManualDecoding(
        _ data: Data,
        contentEncoding: String?
    ) -> Bool {
        isZstandardFrame(data)
            && declaresZstandard(contentEncoding) != false
    }

    static func decode(_ data: Data, contentEncoding: String?) throws -> Data {
        try Task.checkCancellation()
        guard requiresManualDecoding(
            data,
            contentEncoding: contentEncoding
        ) else {
            // URLSession expands gzip and Brotli, and newer CFNetwork versions
            // may also expand zstd before returning the body.
            return data
        }
        return try decompressZstandard(data)
    }

    private static func declaresZstandard(_ value: String?) -> Bool? {
        guard let value else { return nil }
        return value
            .split(separator: ",", omittingEmptySubsequences: true)
            .contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare("zstd") == .orderedSame
            }
    }

    private static func isZstandardFrame(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= 4 else { return false }

            if bytes[0] == zstandardMagic[0],
               bytes[1] == zstandardMagic[1],
               bytes[2] == zstandardMagic[2],
               bytes[3] == zstandardMagic[3] {
                return true
            }

            // RFC 8878 permits skippable frames before a normal Zstandard
            // frame. Their little-endian magic range is
            // 0x184D2A50...0x184D2A5F.
            return (0x50...0x5F).contains(bytes[0])
                && bytes[1] == 0x2A
                && bytes[2] == 0x4D
                && bytes[3] == 0x18
        }
    }

    private static func standardFrameContentSizeHint(
        _ data: Data
    ) throws -> Int? {
        guard data.count >= 4, data.starts(with: zstandardMagic) else {
            return nil
        }
        let value = data.withUnsafeBytes { source -> UInt64 in
            guard let baseAddress = source.baseAddress else { return 0 }
            return ZSTD_getFrameContentSize(baseAddress, source.count)
        }

        // zstd reserves the two largest UInt64 values for UNKNOWN and ERROR.
        // Unknown-size frames continue through the streaming decoder; a known
        // oversized frame can be rejected before allocating decompression RAM.
        guard value < UInt64.max - 1 else { return nil }
        guard value <= UInt64(maximumDecodedBytes),
              value <= UInt64(Int.max) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return Int(value)
    }

    private static func decompressZstandard(_ data: Data) throws -> Data {
        guard let stream = ZSTD_createDStream() else {
            throw URLError(.cannotDecodeContentData)
        }
        defer { ZSTD_freeDStream(stream) }

        let initialization = ZSTD_initDStream(stream)
        guard ZSTD_isError(initialization) == 0 else {
            throw URLError(.cannotDecodeContentData)
        }

        let outputCapacity = max(16_384, Int(ZSTD_DStreamOutSize()))
        var output = Data()
        if let contentSize = try standardFrameContentSizeHint(data) {
            output.reserveCapacity(max(outputCapacity, contentSize))
        } else {
            let estimatedCapacity = data.count > maximumDecodedBytes / 3
                ? maximumDecodedBytes
                : data.count * 3
            output.reserveCapacity(max(outputCapacity, estimatedCapacity))
        }
        var chunk = [UInt8](repeating: 0, count: outputCapacity)

        try data.withUnsafeBytes { source in
            guard let sourceAddress = source.baseAddress else { return }
            var input = ZSTD_inBuffer(src: sourceAddress, size: source.count, pos: 0)
            var remaining = 1

            while input.pos < input.size {
                try Task.checkCancellation()
                let previousInputPosition = input.pos
                var produced = 0
                let result = chunk.withUnsafeMutableBytes { destination -> Int in
                    var buffer = ZSTD_outBuffer(
                        dst: destination.baseAddress,
                        size: destination.count,
                        pos: 0
                    )
                    let status = ZSTD_decompressStream(stream, &buffer, &input)
                    produced = buffer.pos
                    return Int(status)
                }

                guard ZSTD_isError(result) == 0 else {
                    throw URLError(.cannotDecodeContentData)
                }
                guard produced > 0 || input.pos > previousInputPosition || result == 0 else {
                    throw URLError(.cannotDecodeContentData)
                }
                if produced > 0 {
                    try Task.checkCancellation()
                    chunk.withUnsafeBytes { bytes in
                        guard let baseAddress = bytes.baseAddress else { return }
                        output.append(
                            baseAddress.assumingMemoryBound(to: UInt8.self),
                            count: produced
                        )
                    }
                    guard output.count <= maximumDecodedBytes else {
                        throw URLError(.dataLengthExceedsMaximum)
                    }
                }
                remaining = result
                if result == 0, input.pos == input.size { break }
            }
            guard remaining == 0 else {
                throw URLError(.cannotDecodeContentData)
            }
        }
        return output
    }
}
