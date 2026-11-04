#if canImport(Compression)
import Foundation
import PipelineKitCache
import XCTest

final class CompressionFormatContractTests: XCTestCase {
    private let plaintext = Data("Legacy codec fixture: ABCABCABC.".utf8)

    // DEFLATE: Python zlib.compressobj(wbits=-15), not CompressionUtility.
    // LZFSE: fixed COMPRESSION_LZFSE output captured before the API migration.
    // Apple LZ4: hand-built uncompressed block and end marker per SDK compression.h.
    // All bytes are embedded so these tests also run on Apple device/simulator targets.
    private var legacyFixtures: [(String, Data)] {
        let deflate = Data([
            0xf3, 0x49, 0x4d, 0x4f, 0x4c, 0xae, 0x54, 0x48, 0xce, 0x4f, 0x49, 0x4d,
            0x56, 0x48, 0xcb, 0xac, 0x28, 0x29, 0x2d, 0x4a, 0xb5, 0x52, 0x70, 0x74,
            0x72, 0x86, 0x20, 0x3d, 0x00
        ])
        let lzfse = Data([0x62, 0x76, 0x78, 0x2d, 0x20, 0, 0, 0]) + plaintext
            + Data([0x62, 0x76, 0x78, 0x24])
        let lz4 = Data([0x62, 0x76, 0x34, 0x2d, 0x20, 0, 0, 0]) + plaintext
            + Data([0x62, 0x76, 0x34, 0x24])
        return [("zlib", deflate), ("gzip", deflate), ("lzfse", lzfse), ("brotli", lzfse), ("lz4", lz4)]
    }

    func testLegacyLabelsDecodeIndependentOldFormatFixturesWithBoundedHints() throws {
        for (label, fixture) in legacyFixtures {
            let algorithm = try XCTUnwrap(LegacyCompressionAlgorithm(rawValue: label))
            for hint: Int? in [nil, 0, 17, 32, 33, Int.max] {
                for limit in [32, 33, Int.max] {
                    XCTAssertEqual(try CompressionUtility.decompressLegacy(
                        fixture, using: algorithm, originalSize: hint, maxOutputSize: limit
                    ), plaintext, "\(algorithm), hint \(String(describing: hint)), limit \(limit)")
                }
                XCTAssertThrowsError(try CompressionUtility.decompressLegacy(
                    fixture, using: algorithm, originalSize: hint, maxOutputSize: 31
                )) { error in
                    guard case CompressionError.dataTooLarge(31) = error else {
                        return XCTFail("Expected output bound for \(algorithm), got \(error)")
                    }
                }
            }
        }
    }

    func testCanonicalFormatsDecodeIndependentFixtures() throws {
        for (label, fixture) in legacyFixtures {
            let algorithm = try XCTUnwrap(LegacyCompressionAlgorithm(rawValue: label))
            let canonical: CompressionAlgorithm
            switch algorithm {
            case .zlib, .gzip: canonical = .rawDeflate
            case .lzfse, .brotli: canonical = .lzfse
            case .lz4: canonical = .appleLZ4
            }
            XCTAssertEqual(try CompressionUtility.decompress(
                fixture, using: canonical, maxOutputSize: 32
            ), plaintext)
        }
    }

    func testLegacyRoutesRejectMalformedTruncatedTrailingAndConcatenatedStreams() throws {
        for (label, fixture) in legacyFixtures {
            let algorithm = try XCTUnwrap(LegacyCompressionAlgorithm(rawValue: label))
            let invalid = [
                Data(fixture.prefix(1)), Data(fixture.prefix(fixture.count / 2)),
                Data(fixture.dropLast()), Data(repeating: 0xff, count: 32),
                fixture + Data([0]), fixture + Data([0xff, 0x13]), fixture + fixture
            ]
            for data in invalid {
                for hint: Int? in [nil, 0, 32, Int.max] {
                    assertDecodeError {
                        try CompressionUtility.decompressLegacy(
                            data, using: algorithm, originalSize: hint, maxOutputSize: 64
                        )
                    }
                }
            }
        }
    }

    func testLegacyRoutesValidateArgumentsBeforeEmptyCompatibility() throws {
        for (label, fixture) in legacyFixtures {
            let algorithm = try XCTUnwrap(LegacyCompressionAlgorithm(rawValue: label))
            for data in [Data(), fixture] {
                for hint in [-1, Int.min] {
                    assertDecodeError {
                        try CompressionUtility.decompressLegacy(
                            data, using: algorithm, originalSize: hint, maxOutputSize: 32
                        )
                    }
                }
                for limit in [0, -1, Int.min] {
                    assertDecodeError {
                        try CompressionUtility.decompressLegacy(data, using: algorithm, maxOutputSize: limit)
                    }
                }
            }
            XCTAssertEqual(try CompressionUtility.decompressLegacy(
                Data(), using: algorithm, originalSize: Int.max, maxOutputSize: 1
            ), Data())
        }
    }

    func testLegacyEncodedEmptyStreamsRequireCompletion() throws {
        let emptyFixtures: [(LegacyCompressionAlgorithm, Data)] = [
            (.zlib, Data([0x03, 0x00])), (.gzip, Data([0x03, 0x00])),
            (.lzfse, Data([0x62, 0x76, 0x78, 0x24])),
            (.brotli, Data([0x62, 0x76, 0x78, 0x24])),
            (.lz4, Data([0x62, 0x76, 0x34, 0x24]))
        ]
        for (algorithm, fixture) in emptyFixtures {
            XCTAssertEqual(try CompressionUtility.decompressLegacy(
                fixture, using: algorithm, maxOutputSize: 1
            ), Data())
            for invalid in [Data(fixture.dropLast()), fixture + Data([0]), fixture + fixture] {
                assertDecodeError {
                    try CompressionUtility.decompressLegacy(invalid, using: algorithm, maxOutputSize: 1)
                }
            }
        }
    }

    func testSaturatingAllocationEstimate() {
        XCTAssertEqual(CompressionUtility.maxCompressedSize(for: 0), 16)
        XCTAssertEqual(CompressionUtility.maxCompressedSize(for: 1), 17)
        XCTAssertEqual(CompressionUtility.maxCompressedSize(for: 100), 117)
        XCTAssertEqual(CompressionUtility.maxCompressedSize(for: 100_000), 101_016)
        // The one-percent margin fits here, but adding the final 16 bytes does not.
        XCTAssertEqual(CompressionUtility.maxCompressedSize(for: Int.max - Int.max / 101), Int.max)
        XCTAssertEqual(CompressionUtility.maxCompressedSize(for: Int.max - 16), Int.max)
        XCTAssertEqual(CompressionUtility.maxCompressedSize(for: Int.max), Int.max)
    }

    // check_compression_formats.py consumes this output with Python's independent zlib decoder.
    func testRawDeflateOutputInteroperabilityProbe() throws {
        let samples = [Data([0x41]), plaintext, Data(repeating: 0x41, count: 1000), Data(0...255)]
        for original in samples {
            let encoded = try CompressionUtility.compress(original, using: .rawDeflate)
            let record = ["original": original.base64EncodedString(), "compressed": encoded.base64EncodedString()]
            let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            FileHandle.standardOutput.write(Data("COMPRESSION_INTEROP ".utf8) + json + Data([10]))
        }
    }

    private func assertDecodeError(
        file: StaticString = #filePath, line: UInt = #line, _ decode: () throws -> Data
    ) {
        XCTAssertThrowsError(try decode(), file: file, line: line) { error in
            guard case CompressionError.decompressionFailed = error else {
                return XCTFail("Expected decode error, got \(error)", file: file, line: line)
            }
        }
    }
}
#endif
