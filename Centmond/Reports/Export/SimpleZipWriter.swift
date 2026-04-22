import Foundation

// Minimal zero-dependency ZIP writer. STORE method only (no DEFLATE).
// XLSX parts are small and XML-ish; compression ratios don't matter
// enough to pull in a zlib binding. CRC-32 is computed with a runtime
// table so libz linking is never required.

enum SimpleZipWriter {

    struct Entry {
        let path: String      // eg "xl/worksheets/sheet1.xml"
        let data: Data
    }

    static func make(_ entries: [Entry]) -> Data {
        var out = Data()
        var centralDirectory = Data()

        for entry in entries {
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let nameData = entry.path.data(using: .utf8) ?? Data()
            let nameLen = UInt16(nameData.count)
            let localOffset = UInt32(out.count)

            // Local file header
            out.appendLE(UInt32(0x04034b50))  // signature
            out.appendLE(UInt16(20))          // version needed
            out.appendLE(UInt16(0))           // flags
            out.appendLE(UInt16(0))           // method: 0 = STORE
            out.appendLE(UInt16(0))           // mod time
            out.appendLE(UInt16(0))           // mod date
            out.appendLE(crc)                 // crc-32
            out.appendLE(size)                // compressed size
            out.appendLE(size)                // uncompressed size
            out.appendLE(nameLen)             // filename length
            out.appendLE(UInt16(0))           // extra field length
            out.append(nameData)
            out.append(entry.data)

            // Central directory header
            centralDirectory.appendLE(UInt32(0x02014b50))  // signature
            centralDirectory.appendLE(UInt16(20))          // version made by
            centralDirectory.appendLE(UInt16(20))          // version needed
            centralDirectory.appendLE(UInt16(0))           // flags
            centralDirectory.appendLE(UInt16(0))           // method
            centralDirectory.appendLE(UInt16(0))           // mod time
            centralDirectory.appendLE(UInt16(0))           // mod date
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(size)                // compressed size
            centralDirectory.appendLE(size)                // uncompressed size
            centralDirectory.appendLE(nameLen)             // filename length
            centralDirectory.appendLE(UInt16(0))           // extra field length
            centralDirectory.appendLE(UInt16(0))           // comment length
            centralDirectory.appendLE(UInt16(0))           // disk number
            centralDirectory.appendLE(UInt16(0))           // internal attributes
            centralDirectory.appendLE(UInt32(0))           // external attributes
            centralDirectory.appendLE(localOffset)         // offset of local header
            centralDirectory.append(nameData)
        }

        let cdOffset = UInt32(out.count)
        let cdSize = UInt32(centralDirectory.count)
        out.append(centralDirectory)

        // End of central directory record
        out.appendLE(UInt32(0x06054b50))  // signature
        out.appendLE(UInt16(0))           // disk number
        out.appendLE(UInt16(0))           // disk where cd starts
        out.appendLE(UInt16(entries.count))  // entries on this disk
        out.appendLE(UInt16(entries.count))  // total entries
        out.appendLE(cdSize)              // size of central directory
        out.appendLE(cdOffset)            // offset of central directory
        out.appendLE(UInt16(0))           // comment length

        return out
    }

    // MARK: - CRC-32 (IEEE, poly 0xEDB88320)

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for i in 0..<data.count {
                let idx = Int((crc ^ UInt32(bytes[i])) & 0xFF)
                crc = crcTable[idx] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
