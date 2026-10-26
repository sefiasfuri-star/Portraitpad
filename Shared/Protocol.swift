import Foundation

/// Wire protocol shared by the Mac host and the iPad viewer.
///
/// Every message is: 1 byte type, 4 bytes big-endian payload length, payload.
/// The iPad is always the server (it listens on `PP.port`); the Mac connects to it,
/// either over USB (through usbmuxd) or over the network (found with Bonjour).
enum PPMessage: UInt8 {
    /// iPad -> Mac. JSON-encoded `Hello`, sent as soon as the connection opens.
    case hello = 1
    /// Mac -> iPad. H.264 parameter sets: u8 count, then (u16 length, bytes) per set.
    case format = 2
    /// Mac -> iPad. u8 flags (bit 0 = keyframe), then one AVCC access unit (4-byte NAL lengths).
    case frame = 3
    /// iPad -> Mac. u8 phase (`PointerPhase`), f32 x, f32 y. Coordinates are normalized 0...1.
    case pointer = 10
    /// iPad -> Mac. f32 x, f32 y (normalized position), f32 dx, f32 dy (iPad points).
    case scroll = 11
    /// iPad -> Mac. Empty. Asks the encoder for a fresh keyframe (e.g. after a decode error).
    case keyframeRequest = 12
}

enum PointerPhase: UInt8 {
    case down = 0
    case drag = 1
    case up = 2
    case rightClick = 3
}

struct Hello: Codable {
    /// Native pixel size of the iPad screen in portrait orientation.
    var pixelWidth: Int
    var pixelHeight: Int
    /// Pixels per inch, used to give the virtual display a realistic physical size.
    var ppi: Double
    var name: String
}

enum PP {
    static let port: UInt16 = 9123
    static let bonjourType = "_portraitpad._tcp"
    static let maxPayload = 64 * 1024 * 1024
}

struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }

    mutating func u16(_ v: UInt16) {
        data.append(UInt8(v >> 8))
        data.append(UInt8(v & 0xff))
    }

    mutating func u32(_ v: UInt32) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    mutating func f32(_ v: Float) { u32(v.bitPattern) }

    mutating func bytes(_ d: Data) { data.append(d) }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() -> UInt16? {
        guard let a = u8(), let b = u8() else { return nil }
        return UInt16(a) << 8 | UInt16(b)
    }

    mutating func u32() -> UInt32? {
        guard let a = u16(), let b = u16() else { return nil }
        return UInt32(a) << 16 | UInt32(b)
    }

    mutating func f32() -> Float? {
        guard let bits = u32() else { return nil }
        return Float(bitPattern: bits)
    }

    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, remaining >= n else { return nil }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }

    mutating func rest() -> Data {
        bytes(remaining) ?? Data()
    }
}
