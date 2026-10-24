import Foundation

/// A JSON value that round-trips without loss: object key order is kept and numbers keep their exact source
/// lexeme (so `1`, `1.0` and `1e3` are written back as they were read). Document bodies are edited through this
/// type so fields the native editor does not understand survive a save unchanged.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case (.bool(let x), .bool(let y)): x == y
        case (.number(let x), .number(let y)): x == y
        case (.string(let x), .string(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.object(let x), .object(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.last { $0.0 == key }?.1
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var objectValue: [(String, JSONValue)]? { if case .object(let o) = self { o } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var intValue: Int? { if case .number(let n) = self { Int(n) ?? Double(n).flatMap { $0.rounded() == $0 ? Int($0) : nil } } else { nil } }
    public var isObject: Bool { if case .object = self { true } else { false } }

    /// Returns a copy with `key` set (replacing an existing key in place, or appended when new).
    public func setting(_ key: String, _ value: JSONValue?) -> JSONValue {
        guard case .object(var pairs) = self else { return self }
        if let index = pairs.firstIndex(where: { $0.0 == key }) {
            if let value { pairs[index].1 = value } else { pairs.remove(at: index) }
        } else if let value {
            pairs.append((key, value))
        }
        return .object(pairs)
    }

    public static func int(_ value: Int) -> JSONValue { .number(String(value)) }

    // MARK: Parse

    public enum ParseError: Error, Equatable { case invalid(Int), trailing(Int), depth }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError.trailing(parser.index) }
        return value
    }

    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        static let maxDepth = 512

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw ParseError.invalid(index) }
                index += 1
            }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < Self.maxDepth else { throw ParseError.depth }
            guard index < bytes.count else { throw ParseError.invalid(index) }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var pairs: [(String, JSONValue)] = []
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                while true {
                    skipWhitespace()
                    let key = try string()
                    skipWhitespace()
                    try expect(":")
                    skipWhitespace()
                    pairs.append((key, try value(depth: depth + 1)))
                    skipWhitespace()
                    guard index < bytes.count else { throw ParseError.invalid(index) }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                    throw ParseError.invalid(index)
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [JSONValue] = []
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    skipWhitespace()
                    items.append(try value(depth: depth + 1))
                    skipWhitespace()
                    guard index < bytes.count else { throw ParseError.invalid(index) }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                    throw ParseError.invalid(index)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func number() throws -> String {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            func digits() -> Int { let s = index; while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }; return index - s }
            guard digits() > 0 else { throw ParseError.invalid(start) }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") { index += 1; guard digits() > 0 else { throw ParseError.invalid(index) } }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw ParseError.invalid(index) }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError.invalid(index) }
            index += 1
            var out = [UInt8]()
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { index += 1; return String(decoding: out, as: UTF8.self) }
                if byte < 0x20 { throw ParseError.invalid(index) }
                if byte != UInt8(ascii: "\\") { out.append(byte); index += 1; continue }
                index += 1
                guard index < bytes.count else { throw ParseError.invalid(index) }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // A surrogate pair encodes one scalar outside the BMP.
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { throw ParseError.invalid(index) }
                        index += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw ParseError.invalid(index) }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw ParseError.invalid(index)
                    }
                    guard let unicode = Unicode.Scalar(scalar) else { throw ParseError.invalid(index) }
                    out.append(contentsOf: Array(String(Character(unicode)).utf8))
                default: throw ParseError.invalid(index)
                }
            }
            throw ParseError.invalid(index)
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw ParseError.invalid(index)
            }
            index += 4
            return value
        }
    }

    // MARK: Serialize

    /// Compact JSON in the same escaping style as `JSON.stringify` (the web client's writer).
    public func serialized() -> Data { Data(serializedString().utf8) }

    public func serializedString() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += NostrSerialization.quote(s)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() { if i > 0 { out += "," }; item.write(into: &out) }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                out += NostrSerialization.quote(pair.0)
                out += ":"
                pair.1.write(into: &out)
            }
            out += "}"
        }
    }
}
