import Foundation

/// A ZIP container, written.
///
/// Only what a `.docx` needs: stored (uncompressed) entries with a central
/// directory. Uncompressed because a Word file is mostly XML *text*, which
/// store already keeps readable, and because Apple's libcompression only
/// offers a zlib-wrapped deflate — the ZIP container wants raw deflate,
/// and a file that is 30% larger is a far better outcome than a document
/// Word refuses to open.
///
/// Nothing here reads a ZIP: imports go through AppKit's text system,
/// which handles real Word and Google Docs files (and their compression)
/// far better than a hand-rolled inflater would.
public enum ZipWriter {
    public struct Entry {
        public let name: String
        public let data: Data
        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// A fixed timestamp rather than `Date()`: an archive that embeds the
    /// build time can't be compared in a test, and Word does not care what
    /// the mtime says. (1980-01-01 is the DOS epoch; earlier dates are not
    /// representable.)
    static let dosTime: UInt16 = 0
    static let dosDate: UInt16 = 0x0021

    public static func archive(_ entries: [Entry]) -> Data {
        var out = Data()
        var directory = Data()
        for entry in entries {
            let offset = UInt32(out.count)
            let name = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let nameLength = UInt16(name.count)
            // Local file header. Flags stay 0: the names are ASCII, so
            // there is no name to encode in UTF-8, and a reader that
            // trusts bit 11 will read them correctly.
            appendLittle(UInt32(0x04034b50), to: &out)
            appendLittle(UInt16(20), to: &out)        // version needed
            appendLittle(UInt16(0), to: &out)         // flags
            appendLittle(UInt16(0), to: &out)         // stored
            appendLittle(dosTime, to: &out)
            appendLittle(dosDate, to: &out)
            appendLittle(crc, to: &out)
            appendLittle(size, to: &out)              // compressed size
            appendLittle(size, to: &out)              // uncompressed size
            appendLittle(nameLength, to: &out)
            appendLittle(UInt16(0), to: &out)         // extra length
            out.append(name)
            out.append(entry.data)

            appendLittle(UInt32(0x02014b50), to: &directory)
            appendLittle(UInt16(20), to: &directory)  // version made by
            appendLittle(UInt16(20), to: &directory)  // version needed
            appendLittle(UInt16(0), to: &directory)   // flags
            appendLittle(UInt16(0), to: &directory)   // stored
            appendLittle(dosTime, to: &directory)
            appendLittle(dosDate, to: &directory)
            appendLittle(crc, to: &directory)
            appendLittle(size, to: &directory)
            appendLittle(size, to: &directory)
            appendLittle(nameLength, to: &directory)
            appendLittle(UInt16(0), to: &directory)   // extra
            appendLittle(UInt16(0), to: &directory)   // comment
            appendLittle(UInt16(0), to: &directory)   // disk number
            appendLittle(UInt16(0), to: &directory)   // internal attrs
            appendLittle(UInt32(0), to: &directory)   // external attrs
            appendLittle(offset, to: &directory)
            directory.append(name)
        }
        let directoryOffset = UInt32(out.count)
        out.append(directory)
        // End of central directory.
        appendLittle(UInt32(0x06054b50), to: &out)
        appendLittle(UInt16(0), to: &out)
        appendLittle(UInt16(0), to: &out)
        appendLittle(UInt16(entries.count), to: &out)
        appendLittle(UInt16(entries.count), to: &out)
        appendLittle(UInt32(directory.count), to: &out)
        appendLittle(directoryOffset, to: &out)
        appendLittle(UInt16(0), to: &out)            // comment length
        return out
    }
}

/// Little-endian is what ZIP is defined in. Free function rather than a
/// method on `Data` because a `to:`-labelled mutating helper reads like a
/// second `append` and hides which buffer it writes.
func appendLittle<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

/// CRC-32 as ZIP defines it (IEEE 802.3, reflected, init/xor 0xFFFFFFFF).
/// Every ZIP entry carries one, and a document Word rejects over a bad
/// checksum is a document the user has lost work into.
enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}