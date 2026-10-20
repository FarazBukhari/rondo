import Foundation
import Compression

/// In-memory ZIP builder for OOXML / EPUB containers. Entries keep insertion order
/// (EPUB requires `mimetype` first and stored). Deflate via Compression's raw-DEFLATE `COMPRESSION_ZLIB`.
struct ZipBuilder {
    private var body = Data()
    private var directory = Data()
    private var entries = 0
    private let time: UInt16
    private let date: UInt16

    init(date now: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        date = UInt16((max(0, (c.year ?? 1980) - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    mutating func add(_ path: String, _ data: Data, store: Bool = false) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let packed = store ? nil : Self.deflate(data)
        let payload = packed ?? data
        let method: UInt16 = packed == nil ? 0 : 8
        let flags: UInt16 = path.allSatisfy(\.isASCII) ? 0 : 0x0800
        let offset = UInt32(body.count)

        var local = Data()
        local.le32(0x0403_4B50)
        local.le16(20); local.le16(flags); local.le16(method)
        local.le16(time); local.le16(date)
        local.le32(crc); local.le32(UInt32(payload.count)); local.le32(UInt32(data.count))
        local.le16(UInt16(name.count)); local.le16(0)
        local.append(name)
        body.append(local)
        body.append(payload)

        var cd = Data()
        cd.le32(0x0201_4B50)
        cd.le16(0x0314); cd.le16(20); cd.le16(flags); cd.le16(method)   // made by: Unix, v2.0
        cd.le16(time); cd.le16(date)
        cd.le32(crc); cd.le32(UInt32(payload.count)); cd.le32(UInt32(data.count))
        cd.le16(UInt16(name.count)); cd.le16(0); cd.le16(0)
        cd.le16(0); cd.le16(0)
        cd.le32(UInt32(0o100644) << 16)                                 // external attrs: -rw-r--r--
        cd.le32(offset)
        cd.append(name)
        directory.append(cd)
        entries += 1
    }

    mutating func add(_ path: String, _ text: String, store: Bool = false) {
        add(path, Data(text.utf8), store: store)
    }

    func finish() -> Data {
        var out = body
        let cdOffset = UInt32(out.count)
        out.append(directory)
        out.le32(0x0605_4B50)
        out.le16(0); out.le16(0)
        out.le16(UInt16(entries)); out.le16(UInt16(entries))
        out.le32(UInt32(directory.count)); out.le32(cdOffset)
        out.le16(0)
        return out
    }

    /// Raw DEFLATE (RFC 1951); nil when it wouldn't shrink the data.
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

/// XML text escaping shared by the EPUB/XHTML/OOXML writers.
enum XML {
    static func escape(_ s: String, quotes: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where quotes: out += "&quot;"
            default:
                // Drop characters XML 1.0 forbids (C0 controls except tab/newline/CR).
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                if ch.value == 0xFFFE || ch.value == 0xFFFF { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
