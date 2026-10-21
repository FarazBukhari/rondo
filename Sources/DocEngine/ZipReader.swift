import Foundation
import Compression

/// Read-only ZIP central-directory parser and bounded in-memory member reader.
/// Used to pre-scan archives before `ditto -x` (names, symlinks, sizes) and to read XLSX parts without
/// touching the disk (so symlink members can't redirect reads to /dev/zero or the user's files).
struct ZipEntry: Equatable {
    var name: String
    var versionMadeBy: UInt16
    var flags: UInt16
    var method: UInt16
    var crc: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var localHeaderOffset: UInt64
    var externalAttributes: UInt32

    var isDirectory: Bool { name.hasSuffix("/") || (unixMode.map { $0 & 0o170000 == 0o040000 } ?? false) }
    var isEncrypted: Bool { flags & 1 != 0 }

    /// Unix mode bits when the entry was made on Unix/macOS.
    var unixMode: UInt32? {
        let host = versionMadeBy >> 8
        guard host == 3 || host == 19 else { return nil }
        let mode = externalAttributes >> 16
        return mode == 0 ? nil : mode
    }

    var isSymlink: Bool { (unixMode.map { $0 & 0o170000 == 0o120000 }) ?? false }
}

enum ZipReader {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func fail(_ s: String) -> Failure { Failure(description: s) }

    /// All central-directory entries. Throws on a malformed archive or more than `maxEntries` entries.
    static func entries(_ url: URL, maxEntries: Int = 1_000_000) throws -> [ZipEntry] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        guard size >= 22 else { throw fail("too small to be a ZIP") }

        // End of central directory: last 22 bytes + up to 64 KB comment.
        let tailLength = min(size, 22 + 65_535)
        let tail = try read(fh, at: size - tailLength, count: Int(tailLength))
        guard let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else { throw fail("no end-of-central-directory record") }
        var count = UInt64(tail.u16(eocd + 10))
        var cdSize = UInt64(tail.u32(eocd + 12))
        var cdOffset = UInt64(tail.u32(eocd + 16))

        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64: locator sits right before the EOCD record.
            let eocdAt = size - tailLength + UInt64(eocd)
            guard eocdAt >= 20 else { throw fail("missing ZIP64 locator") }
            let locator = try read(fh, at: eocdAt - 20, count: 20)
            guard locator.u32(0) == 0x0706_4B50 else { throw fail("missing ZIP64 locator") }
            let z64At = locator.u64(8)
            guard z64At < size else { throw fail("bad ZIP64 record offset") }
            let z64 = try read(fh, at: z64At, count: 56)
            guard z64.u32(0) == 0x0606_4B50 else { throw fail("bad ZIP64 end record") }
            count = z64.u64(32); cdSize = z64.u64(40); cdOffset = z64.u64(48)
        }
        guard count <= UInt64(maxEntries) else { throw fail("has more than \(maxEntries) entries") }
        guard cdOffset <= size, cdSize <= size - cdOffset, cdSize <= 512 * 1024 * 1024 else { throw fail("central directory out of range") }

        let cd = try read(fh, at: cdOffset, count: Int(cdSize))
        var out: [ZipEntry] = []
        out.reserveCapacity(Int(count))
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.u32(p) == 0x0201_4B50 else { throw fail("corrupt central directory") }
            let nameLen = Int(cd.u16(p + 28)), extraLen = Int(cd.u16(p + 30)), commentLen = Int(cd.u16(p + 32))
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { throw fail("corrupt central directory") }
            let flags = cd.u16(p + 8)
            let nameBytes = cd.subdata(in: (p + 46)..<(p + 46 + nameLen))
            var e = ZipEntry(name: decodeName(nameBytes, utf8: flags & 0x0800 != 0),
                             versionMadeBy: cd.u16(p + 4), flags: flags, method: cd.u16(p + 10), crc: cd.u32(p + 16),
                             compressedSize: UInt64(cd.u32(p + 20)), uncompressedSize: UInt64(cd.u32(p + 24)),
                             localHeaderOffset: UInt64(cd.u32(p + 42)), externalAttributes: cd.u32(p + 38))
            // ZIP64 extra field (id 1) carries whichever 32-bit fields were saturated, in this order.
            var x = p + 46 + nameLen
            let xEnd = x + extraLen
            while x + 4 <= xEnd {
                let id = cd.u16(x), len = Int(cd.u16(x + 2))
                guard x + 4 + len <= xEnd else { break }
                if id == 1 {
                    var q = x + 4
                    func next() -> UInt64? { guard q + 8 <= x + 4 + len else { return nil }; defer { q += 8 }; return cd.u64(q) }
                    if e.uncompressedSize == 0xFFFF_FFFF, let v = next() { e.uncompressedSize = v }
                    if e.compressedSize == 0xFFFF_FFFF, let v = next() { e.compressedSize = v }
                    if e.localHeaderOffset == 0xFFFF_FFFF, let v = next() { e.localHeaderOffset = v }
                }
                x += 4 + len
            }
            out.append(e)
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    /// Reads one member fully into memory (stored or deflated), refusing anything over `maxBytes`.
    /// Checks that the local header names the same file as the central directory, and verifies the CRC.
    static func read(_ url: URL, entry: ZipEntry, maxBytes: Int) throws -> Data {
        guard !entry.isEncrypted else { throw fail("\(entry.name) is encrypted") }
        guard entry.uncompressedSize <= UInt64(maxBytes), entry.compressedSize <= UInt64(maxBytes) + 1024 else {
            throw fail("\(entry.name) is larger than \(maxBytes / 1_048_576) MB")
        }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        guard entry.localHeaderOffset < size else { throw fail("bad local header offset for \(entry.name)") }
        let local = try read(fh, at: entry.localHeaderOffset, count: 30)
        guard local.count == 30, local.u32(0) == 0x0403_4B50 else { throw fail("bad local header for \(entry.name)") }
        let nameLen = Int(local.u16(26)), extraLen = Int(local.u16(28))
        let localName = try read(fh, at: entry.localHeaderOffset + 30, count: nameLen)
        guard decodeName(localName, utf8: local.u16(6) & 0x0800 != 0) == entry.name else {
            throw fail("local and central names differ for \(entry.name)")
        }
        let payload = try read(fh, at: entry.localHeaderOffset + 30 + UInt64(nameLen + extraLen), count: Int(entry.compressedSize))
        guard payload.count == Int(entry.compressedSize) else { throw fail("truncated member \(entry.name)") }

        let data: Data
        switch entry.method {
        case 0:
            data = payload
        case 8:
            data = try inflate(payload, expected: Int(entry.uncompressedSize))
        default:
            throw fail("\(entry.name) uses unsupported compression method \(entry.method)")
        }
        guard data.count == Int(entry.uncompressedSize), CRC32.checksum(data) == entry.crc else {
            throw fail("\(entry.name) is corrupt (size/CRC mismatch)")
        }
        return data
    }

    /// Raw DEFLATE → exactly `expected` bytes at most (the output buffer is the cap).
    static func inflate(_ input: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var out = Data(count: expected)
        let n = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        out.count = n
        return out
    }

    static func decodeName(_ bytes: Data, utf8: Bool) -> String {
        if let s = String(data: bytes, encoding: .utf8) { return s }
        // CP437 / unknown legacy encodings: "/", "\" and "." are ASCII in all of them, which is what the checks need.
        return String(data: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func read(_ fh: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        try fh.seek(toOffset: offset)
        return try fh.read(upToCount: count) ?? Data()
    }

    private static func lastIndex(of sig: [UInt8], in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let bytes = [UInt8](data)
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == sig[0], bytes[i + 1] == sig[1], bytes[i + 2] == sig[2], bytes[i + 3] == sig[3] { return i }
            i -= 1
        }
        return nil
    }
}

extension Data {
    func u16(_ i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= count else { return 0 }
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }

    func u32(_ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= count else { return 0 }
        return UInt32(u16(i)) | UInt32(u16(i + 2)) << 16
    }

    func u64(_ i: Int) -> UInt64 {
        guard i >= 0, i + 8 <= count else { return 0 }
        return UInt64(u32(i)) | UInt64(u32(i + 4)) << 32
    }
}
