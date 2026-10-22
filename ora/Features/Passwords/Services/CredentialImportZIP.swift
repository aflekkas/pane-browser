import Foundation
import zlib

/// Strict bounded ZIP subset: single disk, no encryption/ZIP64/data descriptors; stored or raw DEFLATE.
/// No extraction, no paths opened. Unsupported features are reported instead of guessing their layout.
enum CredentialImportZIP {
    struct Entry {
        let name: [UInt8]
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let size: Int
        let compressed: Int
        let offset: Int
        var normalizedName: String {
            let raw = String(bytes: name, encoding: .utf8) ?? ""
            return raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
        }
    }

    static func exportData(_ data: Data, cancelled: () -> Bool) throws -> Data {
        guard data.count <= CredentialImport.maximumArchiveBytes, !cancelled() else {
            throw CredentialImport.ImportFailure.limit
        }
        let bytes = Array(data)
        let (entries, directoryStart) = try directory(bytes)
        let targets = entries.filter { $0.normalizedName == "export.data" }
        guard targets.count == 1, let target = targets.first else { throw CredentialImport.ImportFailure.malformed }
        var ranges: [Range<Int>] = []
        var targetRange: Range<Int>?
        for entry in entries {
            if cancelled() {
                throw CredentialImport.ImportFailure.cancelled
            }
            let range = try bodyRange(entry, bytes: bytes, directoryStart: directoryStart)
            let fullRange = entry.offset ..< range.upperBound
            guard !ranges.contains(where: { $0.overlaps(fullRange) })
            else { throw CredentialImport.ImportFailure.malformed }
            ranges.append(fullRange)
            if entry.offset == target.offset {
                targetRange = range
            }
        }
        guard let targetRange, target.size <= CredentialImport.maximumExportDataBytes else {
            throw CredentialImport.ImportFailure.limit
        }
        let compressed = Array(bytes[targetRange])
        let decoded: Data
        switch target.method {
        case 0:
            guard compressed.count == target.size else { throw CredentialImport.ImportFailure.malformed }
            decoded = Data(compressed)
        case 8: decoded = try inflate(compressed, size: target.size, cancelled: cancelled)
        default: throw CredentialImport.ImportFailure.malformed
        }
        guard !cancelled(), crc32(decoded) == target.crc else { throw CredentialImport.ImportFailure.malformed }
        return decoded
    }

    private static func directory(_ bytes: [UInt8]) throws -> ([Entry], Int) {
        guard bytes.count >= 22 else { throw CredentialImport.ImportFailure.malformed }
        let lower = max(0, bytes.count - 65557)
        guard let end = stride(from: bytes.count - 22, through: lower, by: -1).first(where: {
            u32(bytes, $0) == 0x06054B50 && Int(u16(bytes, $0 + 20)) == bytes.count - $0 - 22
        }) else { throw CredentialImport.ImportFailure.malformed }
        let count = Int(u16(bytes, end + 10))
        let size = Int(u32(bytes, end + 12))
        let start = Int(u32(bytes, end + 16))
        guard u16(bytes, end + 4) == 0, u16(bytes, end + 6) == 0,
              Int(u16(bytes, end + 8)) == count,
              count <= CredentialImport.maximumArchiveEntries,
              size != Int(UInt32.max), start != Int(UInt32.max),
              start <= end, size == end - start else { throw CredentialImport.ImportFailure.malformed }
        var cursor = start
        var entries: [Entry] = []
        for _ in 0 ..< count {
            guard cursor <= end, end - cursor >= 46, u32(bytes, cursor) == 0x02014B50 else {
                throw CredentialImport.ImportFailure.malformed
            }
            let nameSize = Int(u16(bytes, cursor + 28))
            let extraSize = Int(u16(bytes, cursor + 30))
            let commentSize = Int(u16(bytes, cursor + 32))
            let length = 46 + nameSize + extraSize + commentSize
            guard length <= end - cursor, u16(bytes, cursor + 34) == 0 else {
                throw CredentialImport.ImportFailure.malformed
            }
            let entry = Entry(
                name: Array(bytes[cursor + 46 ..< cursor + 46 + nameSize]),
                flags: u16(bytes, cursor + 8),
                method: u16(bytes, cursor + 10),
                crc: u32(bytes, cursor + 16),
                size: Int(u32(bytes, cursor + 24)),
                compressed: Int(u32(bytes, cursor + 20)),
                offset: Int(u32(bytes, cursor + 42))
            )
            // Permit UTF-8 and deflate compression-option bits only; reject descriptor/encryption flags.
            guard entry.flags & ~UInt16(0x0806) == 0, entry.size != Int(UInt32.max),
                  entry.compressed != Int(UInt32.max), entry.offset != Int(UInt32.max),
                  !entry.name.isEmpty, String(bytes: entry.name, encoding: .utf8) != nil
            else {
                throw CredentialImport.ImportFailure.malformed
            }
            try validateExtra(bytes, range: cursor + 46 + nameSize ..< cursor + 46 + nameSize + extraSize)
            entries.append(entry)
            cursor += length
        }
        guard cursor == end else { throw CredentialImport.ImportFailure.malformed }
        return (entries, start)
    }

    private static func bodyRange(_ entry: Entry, bytes: [UInt8], directoryStart: Int) throws -> Range<Int> {
        let offset = entry.offset
        guard offset <= directoryStart, directoryStart - offset >= 30,
              u32(bytes, offset) == 0x04034B50,
              u16(bytes, offset + 6) == entry.flags, u16(bytes, offset + 8) == entry.method,
              u32(bytes, offset + 14) == entry.crc,
              Int(u32(bytes, offset + 18)) == entry.compressed,
              Int(u32(bytes, offset + 22)) == entry.size else { throw CredentialImport.ImportFailure.malformed }
        let nameSize = Int(u16(bytes, offset + 26))
        let extraSize = Int(u16(bytes, offset + 28))
        let headerSize = 30 + nameSize + extraSize
        guard headerSize <= directoryStart - offset else { throw CredentialImport.ImportFailure.malformed }
        let start = offset + headerSize
        guard entry.compressed <= directoryStart - start,
              Array(bytes[offset + 30 ..< offset + 30 + nameSize]) == entry.name
        else {
            throw CredentialImport.ImportFailure.malformed
        }
        try validateExtra(bytes, range: offset + 30 + nameSize ..< start)
        return start ..< start + entry.compressed
    }

    private static func validateExtra(_ bytes: [UInt8], range: Range<Int>) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard range.upperBound - cursor >= 4, u16(bytes, cursor) != 1 else {
                throw CredentialImport.ImportFailure.malformed
            }
            let length = Int(u16(bytes, cursor + 2))
            guard length <= range.upperBound - cursor - 4 else { throw CredentialImport.ImportFailure.malformed }
            cursor += 4 + length
        }
    }

    private static func inflate(_ bytes: [UInt8], size: Int, cancelled: () -> Bool) throws -> Data {
        // Apple's Compression decoder consumes trailing input at END. zlib exposes exact total_in;
        // use raw RFC1951 mode, insist on Z_STREAM_END and exact total_in/total_out (including +1 overflow).
        var output = [UInt8](repeating: 0, count: size + 1)
        let produced = try output.withUnsafeMutableBufferPointer { destination in
            try bytes.withUnsafeBufferPointer { source -> Int in
                guard let src = source.baseAddress, let dst = destination.baseAddress else {
                    throw CredentialImport.ImportFailure.malformed
                }
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
                else { throw CredentialImport.ImportFailure.malformed }
                defer { inflateEnd(&stream) }
                stream.next_in = UnsafeMutablePointer(mutating: src)
                stream.avail_in = uInt(source.count)
                stream.next_out = dst
                stream.avail_out = uInt(destination.count)
                while true {
                    if cancelled() {
                        throw CredentialImport.ImportFailure.cancelled
                    }
                    let inputBefore = stream.total_in
                    let outputBefore = stream.total_out
                    let status = zlib.inflate(&stream, Z_FINISH)
                    if status == Z_STREAM_END {
                        guard stream.total_in == source.count else { throw CredentialImport.ImportFailure.malformed }
                        return Int(stream.total_out)
                    }
                    guard status == Z_OK, stream.avail_out > 0,
                          stream.total_in > inputBefore || stream.total_out > outputBefore
                    else {
                        throw CredentialImport.ImportFailure.malformed
                    }
                }
            }
        }
        guard produced == size else { throw CredentialImport.ImportFailure.malformed }
        return Data(output.prefix(size))
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8)
        }
        return crc ^ UInt32.max
    }

    private static let crcTable: [UInt32] = (0 ... 255).map { seed in
        var value = UInt32(seed)
        for _ in 0 ..< 8 {
            value = value & 1 == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1
        }
        return value
    }
}
