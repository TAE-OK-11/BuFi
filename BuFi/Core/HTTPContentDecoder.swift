import Foundation
import libzstd

enum HTTPContentDecoder {
    private static let zstandardMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    private static let maximumDecodedBytes = 64 * 1_024 * 1_024

    static func decode(_ data: Data, contentEncoding: String?) throws -> Data {
        try Task.checkCancellation()
        guard isZstandardFrame(data) else {
            // URLSession expands gzip and Brotli, and newer CFNetwork versions
            // may also expand zstd before returning the body.
            return data
        }
        guard declaresZstandard(contentEncoding) != false else {
            return data
        }
        return try decompressZstandard(data)
    }

    private static func declaresZstandard(_ value: String?) -> Bool? {
        guard let value else { return nil }
        return value
            .split(separator: ",", omittingEmptySubsequences: true)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            .contains("zstd")
    }

    private static func isZstandardFrame(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        if data.starts(with: zstandardMagic) { return true }

        // RFC 8878 permits skippable frames before a normal Zstandard frame.
        // Their little-endian magic range is 0x184D2A50...0x184D2A5F.
        let prefix = Array(data.prefix(4))
        return (0x50...0x5F).contains(prefix[0])
            && prefix[1] == 0x2A
            && prefix[2] == 0x4D
            && prefix[3] == 0x18
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
        let estimatedCapacity = data.count > maximumDecodedBytes / 3
            ? maximumDecodedBytes
            : data.count * 3
        output.reserveCapacity(max(outputCapacity, estimatedCapacity))
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
                }
                guard output.count <= maximumDecodedBytes else {
                    throw URLError(.dataLengthExceedsMaximum)
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
