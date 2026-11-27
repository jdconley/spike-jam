import SpikeCore

/// A compact binary `Encoder` and `Decoder` for Codable values, for the wire (plan 6).
///
/// The format has no keys and no type tags: both ends run the same code, so a value is read back
/// in the order it was written.
/// - Fixed-width types (`Int8`…`Int64`, `UInt8`…`UInt64`) are little-endian at their own width,
///   and `Float` and `Double` are their little-endian IEEE bits.
/// - `Int` and `UInt` are varints (zig-zag for `Int`): ticks, indices and enum raw values are
///   small, and SpikeCore uses `Int` for all of them.
/// - `Bool` is one byte. A `String` is a varint: odd, it's `2 × i + 1` for entry `i` of
///   `StringTable` (the enum names SpikeCore codes), else twice the UTF-8 byte count, then the
///   UTF-8.
/// - An optional is a presence byte (0 or 1), then the value if present.
/// - An array is a varint count, then its elements. Any other unkeyed container has a 2-byte
///   little-endian count.
/// - A keyed container is its values in order, without keys, except a nested container, which is
///   written after its key's name. Synthesized enum coding nests each case's payload under the
///   case name, so the case name is all an enum costs.
///
/// Dictionaries with `String` or `Int` keys would code as keyed containers and lose their keys;
/// SpikeCore codes its dictionaries as sorted lists, and nothing here may use one.
public struct BinaryEncoder: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        let sink = Sink()
        try _BinaryEncoder(sink: sink).encodeValue(value)
        for (at, counter) in sink.counts {
            guard counter.n <= Int(UInt16.max) else { throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "list too long")) }
            sink.bytes[at] = UInt8(counter.n & 0xff)
            sink.bytes[at + 1] = UInt8(counter.n >> 8)
        }
        return sink.bytes
    }
}

public struct BinaryDecoder: Sendable {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        let reader = Reader(bytes)
        let value = try _BinaryDecoder(reader: reader).decodeValue(T.self)
        guard reader.offset == bytes.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(bytes.count - reader.offset) bytes left over"))
        }
        return value
    }
}

/// The strings the wire writes as one byte: the raw values of SpikeCore's string enums and the
/// case names of the enums with payloads. Only ever append to it (a reordering is a new
/// `Wire.version`); a string missing from it is simply written out.
enum StringTable {
    static let strings: [String] = {
        var all: [String] = []
        all += GameType.allCases.map(\.rawValue) + Tempo.allCases.map(\.rawValue) + ["fiveOne", "sixTwo"]
        all += Difficulty.allCases.map(\.rawValue) + ["outside", "middle", "opposite", "setter", "libero"]
        all += Gait.allCases.map(\.rawValue) + PlayCall.allCases.map(\.rawValue) + Combo.allCases.map(\.rawValue)
        all += Grade.allCases.map(\.rawValue) + AttackLane.allCases.map(\.rawValue) + PerimeterRole.allCases.map(\.rawValue)
        all += ["serve", "receive", "set", "attack", "dig", "block"]
        all += ["ace", "serviceError", "kill", "attackError", "handlingError"]
        all += ["net", "out", "shank", "overpass", "doubleContact", "blockedStuff", "tooled", "stuff", "soft", "tool"]
        // The cases of Phase, Pick, InputAction, Message and Celebration.Kind.
        all += ["preServe", "rally", "deadBall", "huddle", "matchOver", "ball", "athlete"]
        all += ["press", "release", "tap", "setTo", "read", "pick", "call", "combo", "switchTo", "ready", "teamSettings"]
        all += ["hello", "welcome", "inputs", "snapshot", "timeHint", "reliable", "ack", "bye"]
        all += ["point", "sideOut", "matchWon", "fire"]
        // Added since; new names go last, so the ones before keep their numbers.
        all += ["paused"]
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }()

    static let index: [String: Int] = Dictionary(uniqueKeysWithValues: strings.enumerated().map { ($1, $0) })
}

enum Varint {
    static func zigzag(_ v: Int64) -> UInt64 { UInt64(bitPattern: (v << 1) ^ (v >> 63)) }
    static func unzigzag(_ v: UInt64) -> Int64 { Int64(bitPattern: v >> 1) ^ -Int64(bitPattern: v & 1) }
}

// MARK: - Encoding

/// Where an encoding goes: one buffer, plus the places of the counts that unkeyed containers
/// fill in at the end.
final class Sink {
    var bytes: [UInt8] = []
    var counts: [(Int, Counter)] = []

    enum Kind {
        case wire(any WireValue.Type)
        case optional(any OptionalEncodable.Type)
        case array(any ArrayEncodable.Type)
        case other
    }

    /// The runtime's conformance checks are slow and lock under load, so each type is checked
    /// once per encoding.
    private var kinds: [ObjectIdentifier: Kind] = [:]

    func kind(of t: Any.Type) -> Kind {
        if let k = kinds[ObjectIdentifier(t)] { return k }
        let k: Kind = if let w = t as? any WireValue.Type { .wire(w) }
            else if let o = t as? any OptionalEncodable.Type { .optional(o) }
            else if let a = t as? any ArrayEncodable.Type { .array(a) }
            else { .other }
        kinds[ObjectIdentifier(t)] = k
        return k
    }

    init() {
        bytes.reserveCapacity(512)
    }

    @inline(__always) func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    @inline(__always) func fixed<I: FixedWidthInteger>(_ v: I) {
        var v = v.littleEndian
        withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
    }

    func int(_ v: Int) { varint(Varint.zigzag(Int64(v))) }
    func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    func float(_ v: Float) { fixed(v.bitPattern) }
    func double(_ v: Double) { fixed(v.bitPattern) }

    func string(_ v: String) {
        if let i = StringTable.index[v] {
            varint(UInt64(2 * i + 1))
        } else {
            let utf8 = Array(v.utf8)
            varint(UInt64(2 * utf8.count))
            bytes += utf8
        }
    }
}

final class Counter {
    var n = 0
}

/// Optionals and arrays are found by type, never by casting a value (`as?` on an optional value
/// looks inside it).
protocol OptionalEncodable {
    func writeOptional(_ e: _BinaryEncoder) throws
}

extension Optional: OptionalEncodable where Wrapped: Encodable {
    func writeOptional(_ e: _BinaryEncoder) throws {
        switch self {
        case .none:
            e.sink.bytes.append(0)
        case .some(let w):
            e.sink.bytes.append(1)
            try e.encodeValue(w)
        }
    }
}

protocol ArrayEncodable {
    func writeArray(_ e: _BinaryEncoder) throws
}

extension Array: ArrayEncodable where Element: Encodable {
    func writeArray(_ e: _BinaryEncoder) throws {
        e.sink.varint(UInt64(count))
        for x in self { try e.encodeValue(x) }
    }
}

struct _BinaryEncoder: Encoder {
    let sink: Sink
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(KeyedEnc<Key>(e: self))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        let c = Counter()
        sink.counts.append((sink.bytes.count, c))
        sink.bytes += [0, 0]
        return UnkeyedEnc(e: self, counter: c)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleEnc(e: self)
    }

    /// Writes one value: a primitive inline, an optional with its presence byte, an array with its
    /// count, anything else through its own `encode(to:)`.
    func encodeValue<T: Encodable>(_ value: T) throws {
        let t = T.self
        if t == Float.self { sink.float(unsafeBitCast(value, to: Float.self)) }
        else if t == Int.self { sink.int(unsafeBitCast(value, to: Int.self)) }
        else if t == Bool.self { sink.bool(unsafeBitCast(value, to: Bool.self)) }
        else if t == String.self { sink.string(value as! String) }
        else if t == Double.self { sink.double(unsafeBitCast(value, to: Double.self)) }
        else if t == UInt32.self { sink.fixed(unsafeBitCast(value, to: UInt32.self)) }
        else if t == UInt8.self { sink.bytes.append(unsafeBitCast(value, to: UInt8.self)) }
        else if t == Int16.self { sink.fixed(unsafeBitCast(value, to: Int16.self)) }
        else if t == UInt16.self { sink.fixed(unsafeBitCast(value, to: UInt16.self)) }
        else if t == Int32.self { sink.fixed(unsafeBitCast(value, to: Int32.self)) }
        else if t == UInt64.self { sink.fixed(unsafeBitCast(value, to: UInt64.self)) }
        else if t == Int64.self { sink.fixed(unsafeBitCast(value, to: Int64.self)) }
        else if t == Int8.self { sink.fixed(unsafeBitCast(value, to: Int8.self)) }
        else if t == UInt.self { sink.varint(UInt64(unsafeBitCast(value, to: UInt.self))) }
        else {
            switch sink.kind(of: t) {
            case .wire(let w): writeWire(w, value)
            case .optional(let o): try writeOptional(o, value)
            case .array(let a): try writeArray(a, value)
            case .other: try value.encode(to: self)
            }
        }
    }

    func writeWire<W: WireValue, T>(_ type: W.Type, _ value: T) {
        (value as! W).write(sink)
    }

    func writeOptional<O: OptionalEncodable, T>(_ type: O.Type, _ value: T) throws {
        try (value as! O).writeOptional(self)
    }

    func writeArray<A: ArrayEncodable, T>(_ type: A.Type, _ value: T) throws {
        try (value as! A).writeArray(self)
    }
}

struct KeyedEnc<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let e: _BinaryEncoder
    var codingPath: [any CodingKey] { [] }

    mutating func encodeNil(forKey key: Key) throws { e.sink.bytes.append(0) }
    mutating func encode(_ v: Bool, forKey key: Key) throws { e.sink.bool(v) }
    mutating func encode(_ v: String, forKey key: Key) throws { e.sink.string(v) }
    mutating func encode(_ v: Double, forKey key: Key) throws { e.sink.double(v) }
    mutating func encode(_ v: Float, forKey key: Key) throws { e.sink.float(v) }
    mutating func encode(_ v: Int, forKey key: Key) throws { e.sink.int(v) }
    mutating func encode(_ v: Int8, forKey key: Key) throws { e.sink.fixed(v) }
    mutating func encode(_ v: Int16, forKey key: Key) throws { e.sink.fixed(v) }
    mutating func encode(_ v: Int32, forKey key: Key) throws { e.sink.fixed(v) }
    mutating func encode(_ v: Int64, forKey key: Key) throws { e.sink.fixed(v) }
    mutating func encode(_ v: UInt, forKey key: Key) throws { e.sink.varint(UInt64(v)) }
    mutating func encode(_ v: UInt8, forKey key: Key) throws { e.sink.fixed(v) }
    mutating func encode(_ v: UInt16, forKey key: Key) throws { e.sink.fixed(v) }
    mutating func encode(_ v: UInt32, forKey key: Key) throws { e.sink.fixed(v) }
    mutating func encode(_ v: UInt64, forKey key: Key) throws { e.sink.fixed(v) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try e.encodeValue(value) }

    // The protocol's own defaults for these skip a nil, which would lose the presence byte.
    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
        guard let value else {
            e.sink.bytes.append(0)
            return
        }
        e.sink.bytes.append(1)
        try e.encodeValue(value)
    }
    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws { try e.encodeValue(value) }
    mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws { try e.encodeValue(value) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        e.sink.string(key.stringValue)
        return e.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        e.sink.string(key.stringValue)
        return e.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder { e }
    mutating func superEncoder(forKey key: Key) -> any Encoder { e }
}

struct UnkeyedEnc: UnkeyedEncodingContainer {
    let e: _BinaryEncoder
    let counter: Counter
    var codingPath: [any CodingKey] { [] }
    var count: Int { counter.n }

    mutating func encodeNil() throws {
        counter.n += 1
        e.sink.bytes.append(0)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        counter.n += 1
        try e.encodeValue(value)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        counter.n += 1
        return e.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        counter.n += 1
        return e.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        counter.n += 1
        return e
    }
}

struct SingleEnc: SingleValueEncodingContainer {
    let e: _BinaryEncoder
    var codingPath: [any CodingKey] { [] }

    mutating func encodeNil() throws { e.sink.bytes.append(0) }
    mutating func encode(_ v: Bool) throws { e.sink.bool(v) }
    mutating func encode(_ v: String) throws { e.sink.string(v) }
    mutating func encode(_ v: Double) throws { e.sink.double(v) }
    mutating func encode(_ v: Float) throws { e.sink.float(v) }
    mutating func encode(_ v: Int) throws { e.sink.int(v) }
    mutating func encode(_ v: Int8) throws { e.sink.fixed(v) }
    mutating func encode(_ v: Int16) throws { e.sink.fixed(v) }
    mutating func encode(_ v: Int32) throws { e.sink.fixed(v) }
    mutating func encode(_ v: Int64) throws { e.sink.fixed(v) }
    mutating func encode(_ v: UInt) throws { e.sink.varint(UInt64(v)) }
    mutating func encode(_ v: UInt8) throws { e.sink.fixed(v) }
    mutating func encode(_ v: UInt16) throws { e.sink.fixed(v) }
    mutating func encode(_ v: UInt32) throws { e.sink.fixed(v) }
    mutating func encode(_ v: UInt64) throws { e.sink.fixed(v) }
    mutating func encode<T: Encodable>(_ value: T) throws { try e.encodeValue(value) }
}

// MARK: - Decoding

final class Reader {
    let bytes: [UInt8]
    var offset = 0

    enum Kind {
        case wire(any WireValue.Type)
        case optional(any OptionalDecodable.Type)
        case array(any ArrayDecodable.Type)
        case other
    }

    private var kinds: [ObjectIdentifier: Kind] = [:]

    /// As `Sink.kind(of:)`.
    func kind(of t: Any.Type) -> Kind {
        if let k = kinds[ObjectIdentifier(t)] { return k }
        let k: Kind = if let w = t as? any WireValue.Type { .wire(w) }
            else if let o = t as? any OptionalDecodable.Type { .optional(o) }
            else if let a = t as? any ArrayDecodable.Type { .array(a) }
            else { .other }
        kinds[ObjectIdentifier(t)] = k
        return k
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func fail(_ why: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(why) at byte \(offset)"))
    }

    @inline(__always) func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw fail("truncated") }
        defer { offset += 1 }
        return bytes[offset]
    }

    func bool() throws -> Bool {
        switch try byte() {
        case 0: return false
        case 1: return true
        default: throw fail("bad bool")
        }
    }

    func varint() throws -> UInt64 {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try byte()
            guard shift < 64 else { throw fail("varint too long") }
            v |= UInt64(b & 0x7f) << shift
            if b < 0x80 { return v }
            shift += 7
        }
    }

    func fixed<I: FixedWidthInteger>(_ type: I.Type) throws -> I {
        let n = MemoryLayout<I>.size
        guard offset + n <= bytes.count else { throw fail("truncated") }
        var v: I = 0
        for i in 0..<n { v |= I(truncatingIfNeeded: bytes[offset + i]) << (8 * i) }
        offset += n
        return v
    }

    func int() throws -> Int { Int(truncatingIfNeeded: Varint.unzigzag(try varint())) }
    func float() throws -> Float { Float(bitPattern: try fixed(UInt32.self)) }
    func double() throws -> Double { Double(bitPattern: try fixed(UInt64.self)) }

    /// A count of things still to read: each takes at least a byte, except empty nested values,
    /// so a corrupt count can't allocate without bound.
    func count(_ n: UInt64) throws -> Int {
        guard n <= UInt64(bytes.count - offset) * 8 + 64 else { throw fail("bad count") }
        return Int(n)
    }

    func string() throws -> String {
        let n = try varint()
        if n & 1 == 1 {
            let i = Int(n >> 1)
            guard i < StringTable.strings.count else { throw fail("bad string index") }
            return StringTable.strings[i]
        }
        let len = Int(n >> 1)
        guard n >> 1 <= UInt64(bytes.count - offset) else { throw fail("truncated") }
        defer { offset += len }
        guard let s = String(validating: bytes[offset..<offset + len], as: UTF8.self) else { throw fail("bad UTF-8") }
        return s
    }
}

protocol OptionalDecodable {
    static func readOptional(_ d: _BinaryDecoder) throws -> Self
}

extension Optional: OptionalDecodable where Wrapped: Decodable {
    static func readOptional(_ d: _BinaryDecoder) throws -> Self {
        try d.reader.bool() ? .some(try d.decodeValue(Wrapped.self)) : .none
    }
}

protocol ArrayDecodable {
    static func readArray(_ d: _BinaryDecoder) throws -> Self
}

extension Array: ArrayDecodable where Element: Decodable {
    static func readArray(_ d: _BinaryDecoder) throws -> Self {
        let n = try d.reader.count(try d.reader.varint())
        var out: [Element] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try d.decodeValue(Element.self)) }
        return out
    }
}

struct _BinaryDecoder: Decoder {
    let reader: Reader
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(KeyedDec<Key>(d: self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        UnkeyedDec(d: self, count: try reader.count(UInt64(try reader.fixed(UInt16.self))))
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleDec(d: self)
    }

    func decodeValue<T: Decodable>(_ type: T.Type) throws -> T {
        let r = reader
        if type == Float.self { return unsafeBitCast(try r.float(), to: T.self) }
        if type == Int.self { return unsafeBitCast(try r.int(), to: T.self) }
        if type == Bool.self { return unsafeBitCast(try r.bool(), to: T.self) }
        if type == String.self { return try r.string() as! T }
        if type == Double.self { return unsafeBitCast(try r.double(), to: T.self) }
        if type == UInt32.self { return unsafeBitCast(try r.fixed(UInt32.self), to: T.self) }
        if type == UInt8.self { return unsafeBitCast(try r.byte(), to: T.self) }
        if type == Int16.self { return unsafeBitCast(try r.fixed(Int16.self), to: T.self) }
        if type == UInt16.self { return unsafeBitCast(try r.fixed(UInt16.self), to: T.self) }
        if type == Int32.self { return unsafeBitCast(try r.fixed(Int32.self), to: T.self) }
        if type == UInt64.self { return unsafeBitCast(try r.fixed(UInt64.self), to: T.self) }
        if type == Int64.self { return unsafeBitCast(try r.fixed(Int64.self), to: T.self) }
        if type == Int8.self { return unsafeBitCast(try r.fixed(Int8.self), to: T.self) }
        if type == UInt.self { return unsafeBitCast(UInt(truncatingIfNeeded: try r.varint()), to: T.self) }
        switch r.kind(of: type) {
        case .wire(let w): return try w.read(r) as! T
        case .optional(let o): return try o.readOptional(self) as! T
        case .array(let a): return try a.readArray(self) as! T
        case .other: return try T(from: self)
        }
    }
}

struct KeyedDec<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let d: _BinaryDecoder
    /// The key `allKeys` read ahead of a nested container (an enum's case).
    private let peeked = PeekedKey()

    init(d: _BinaryDecoder) {
        self.d = d
    }

    final class PeekedKey {
        var name: String?
    }

    var codingPath: [any CodingKey] { [] }

    /// Only enums ask: they nest their payload under the case name, which comes next.
    var allKeys: [Key] {
        if peeked.name == nil { peeked.name = try? d.reader.string() }
        return peeked.name.flatMap { Key(stringValue: $0) }.map { [$0] } ?? []
    }

    func contains(_ key: Key) -> Bool { true }

    func decodeNil(forKey key: Key) throws -> Bool {
        let r = d.reader
        guard r.offset < r.bytes.count, r.bytes[r.offset] == 0 else { return false }
        r.offset += 1
        return true
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try d.reader.bool() }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try d.reader.string() }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try d.reader.double() }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try d.reader.float() }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try d.reader.int() }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try d.reader.fixed(Int8.self) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try d.reader.fixed(Int16.self) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try d.reader.fixed(Int32.self) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try d.reader.fixed(Int64.self) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { UInt(truncatingIfNeeded: try d.reader.varint()) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try d.reader.byte() }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try d.reader.fixed(UInt16.self) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try d.reader.fixed(UInt32.self) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try d.reader.fixed(UInt64.self) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try d.decodeValue(T.self) }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        try d.reader.bool() ? try d.decodeValue(T.self) : nil
    }
    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try d.decodeValue(Bool?.self) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try d.decodeValue(String?.self) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try d.decodeValue(Double?.self) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try d.decodeValue(Float?.self) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try d.decodeValue(Int?.self) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try d.decodeValue(Int8?.self) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try d.decodeValue(Int16?.self) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try d.decodeValue(Int32?.self) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try d.decodeValue(Int64?.self) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try d.decodeValue(UInt?.self) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try d.decodeValue(UInt8?.self) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try d.decodeValue(UInt16?.self) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try d.decodeValue(UInt32?.self) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try d.decodeValue(UInt64?.self) }

    func nestedKey(_ key: Key) throws {
        let name: String
        if let p = peeked.name {
            peeked.name = nil
            name = p
        } else {
            name = try d.reader.string()
        }
        guard name == key.stringValue else { throw d.reader.fail("expected \(key.stringValue), have \(name)") }
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try nestedKey(key)
        return try d.container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try nestedKey(key)
        return try d.unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder { d }
    func superDecoder(forKey key: Key) throws -> any Decoder { d }
}

struct UnkeyedDec: UnkeyedDecodingContainer {
    let d: _BinaryDecoder
    var codingPath: [any CodingKey] { [] }
    var count: Int?
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex >= (count ?? 0) }

    init(d: _BinaryDecoder, count: Int) {
        self.d = d
        self.count = count
    }

    mutating func next() throws {
        guard !isAtEnd else { throw d.reader.fail("past the end of a list") }
        currentIndex += 1
    }

    mutating func decodeNil() throws -> Bool {
        let r = d.reader
        guard !isAtEnd, r.offset < r.bytes.count, r.bytes[r.offset] == 0 else { return false }
        r.offset += 1
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try next()
        return try d.decodeValue(T.self)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try next()
        return try d.container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try next()
        return try d.unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        try next()
        return d
    }
}

struct SingleDec: SingleValueDecodingContainer {
    let d: _BinaryDecoder
    var codingPath: [any CodingKey] { [] }

    func decodeNil() -> Bool {
        let r = d.reader
        guard r.offset < r.bytes.count, r.bytes[r.offset] == 0 else { return false }
        r.offset += 1
        return true
    }

    func decode(_ type: Bool.Type) throws -> Bool { try d.reader.bool() }
    func decode(_ type: String.Type) throws -> String { try d.reader.string() }
    func decode(_ type: Double.Type) throws -> Double { try d.reader.double() }
    func decode(_ type: Float.Type) throws -> Float { try d.reader.float() }
    func decode(_ type: Int.Type) throws -> Int { try d.reader.int() }
    func decode(_ type: Int8.Type) throws -> Int8 { try d.reader.fixed(Int8.self) }
    func decode(_ type: Int16.Type) throws -> Int16 { try d.reader.fixed(Int16.self) }
    func decode(_ type: Int32.Type) throws -> Int32 { try d.reader.fixed(Int32.self) }
    func decode(_ type: Int64.Type) throws -> Int64 { try d.reader.fixed(Int64.self) }
    func decode(_ type: UInt.Type) throws -> UInt { UInt(truncatingIfNeeded: try d.reader.varint()) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try d.reader.byte() }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try d.reader.fixed(UInt16.self) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try d.reader.fixed(UInt32.self) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try d.reader.fixed(UInt64.self) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try d.decodeValue(T.self) }
}
