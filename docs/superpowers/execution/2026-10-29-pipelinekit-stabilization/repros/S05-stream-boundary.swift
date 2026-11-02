import Compression
import Foundation

let codecs: [(String, compression_algorithm)] = [("DEFLATE", COMPRESSION_ZLIB), ("LZFSE", COMPRESSION_LZFSE), ("LZ4", COMPRESSION_LZ4)]
let original = Data(repeating: 65, count: 100_000)
for (name, codec) in codecs {
    let encoded: Data = original.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: 102_000)
        defer { destination.deallocate() }
        let size = compression_encode_buffer(destination, 102_000, source.bindMemory(to: UInt8.self).baseAddress!, original.count, nil, codec)
        precondition(size > 0)
        return Data(bytes: destination, count: size)
    }
    for extra in [Data(), Data([0]), Data([0xFF, 0x13]), encoded] {
        let input = encoded + extra
        for withholdLast in [false, true] {
            input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                let pointer = source.bindMemory(to: UInt8.self).baseAddress!
                let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
                defer { destination.deallocate() }
                var stream = compression_stream(dst_ptr: destination, dst_size: 0, src_ptr: pointer, src_size: 0, state: nil)
                precondition(compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, codec) == COMPRESSION_STATUS_OK)
                defer { compression_stream_destroy(&stream) }
                var supplied = withholdLast ? input.count - 1 : input.count
                stream.src_ptr = pointer
                stream.src_size = supplied
                var output = 0
                var steps = [[String: Int]]()
                for step in 0..<12 {
                    let before = stream.src_size
                    stream.dst_ptr = destination
                    stream.dst_size = 65_536
                    let status = compression_stream_process(&stream, supplied == input.count ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = 65_536 - stream.dst_size
                    output += produced
                    steps.append(["step": step, "supplied": supplied, "remaining": stream.src_size,
                                  "consumed": before - stream.src_size, "produced": produced, "status": Int(status.rawValue)])
                    if status != COMPRESSION_STATUS_OK { break }
                    if before == stream.src_size && produced == 0 {
                        if supplied == input.count { break }
                        precondition(stream.src_size == 0)
                        stream.src_ptr = pointer.advanced(by: supplied)
                        stream.src_size = 1
                        supplied += 1
                    }
                }
                let result: [String: Any] = ["codec": name, "encoded": encoded.count, "trailing": extra.count,
                    "withholdLast": withholdLast, "output": output, "steps": steps]
                let json = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: json, as: UTF8.self))
            }
        }
    }
}
