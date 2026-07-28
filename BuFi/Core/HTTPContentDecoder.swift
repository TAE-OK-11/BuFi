import Foundation
import libzstd

enum HTTPContentDecoder {
    private static let zstandardMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    private static let maximumDecodedBytes = 64 * 1_024 * 1_024

    static func decode(_ data: Data, contentEncoding: String?) throws -> Data {
        guard data.count >= zstandardMagic.count,
              data.starts(with: zstandardMagic) else {
            // URLSession expands gzip and Brotli, and newer CFNetwork versions
            // may also expand zstd before returning the body.
            return data
        }
        guard contentEncoding?.localizedCaseInsensitiveContains("zstd") != false else {
            return data
        }
        return try decompressZstandard(data)
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
                    output.append(contentsOf: chunk.prefix(produced))
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
