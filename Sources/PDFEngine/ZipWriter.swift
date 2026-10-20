import Foundation
import Compression

/// Minimal in-memory ZIP writer (store + raw DEFLATE via Compression's COMPRESSION_ZLIB).
/// Entries are written in the order added — EPUB needs `mimetype` first and stored.
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        dosDate = UInt16((max(0, (c.year ?? 1980) - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    mutating func add(_ name: String, _ data: Data, compress: Bool = true) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let deflated = compress ? Self.deflate(data) : nil
        let payload = deflated ?? data
        let method: UInt16 = deflated == nil ? 0 : 8
        let flags: UInt16 = nameData.count == name.count ? 0 : 0x0800   // UTF-8 names flag only when needed
        let offset = UInt32(body.count)

        var local = Data()
        local.le32(0x0403_4b50)
        local.le16(20); local.le16(flags); local.le16(method)
        local.le16(dosTime); local.le16(dosDate)
        local.le32(crc); local.le32(UInt32(payload.count)); local.le32(UInt32(data.count))
        local.le16(UInt16(nameData.count)); local.le16(0)
        local.append(nameData)
        body.append(local)
        body.append(payload)

        var cd = Data()
        cd.le32(0x0201_4b50)
        cd.le16(20); cd.le16(20); cd.le16(flags); cd.le16(method)
        cd.le16(dosTime); cd.le16(dosDate)
        cd.le32(crc); cd.le32(UInt32(payload.count)); cd.le32(UInt32(data.count))
        cd.le16(UInt16(nameData.count)); cd.le16(0); cd.le16(0)
        cd.le16(0); cd.le16(0); cd.le32(0)
        cd.le32(offset)
        cd.append(nameData)
        central.append(cd)
        count += 1
    }

    func finish() -> Data {
        var out = body
        let cdOffset = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.le32(0x0605_4b50)
        end.le16(0); end.le16(0)
        end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(cdOffset)
        end.le16(0)
        out.append(end)
        return out
    }

    /// Raw DEFLATE (RFC 1951). nil when it wouldn't save space.
    static func deflate(_ input: Data) -> Data? {
        guard input.count > 64 else { return nil }
        let capacity = input.count + 1024
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < input.count else { return nil }
        out.count = n
        return out
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for b in buf.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
