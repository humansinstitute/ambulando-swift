import Foundation

/// NIP-19 Bech32 (not Bech32m) for 32-byte `npub`/`nsec` payloads.
public enum Bech32 {
    static let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

    private static func polymod(_ values: [UInt32]) -> UInt32 {
        var checksum: UInt32 = 1
        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ value
            for (index, generator) in generators.enumerated() where ((top >> index) & 1) != 0 { checksum ^= generator }
        }
        return checksum
    }

    private static func expand(_ hrp: String) -> [UInt32] {
        let bytes = Array(hrp.utf8)
        return bytes.map { UInt32($0 >> 5) } + [0] + bytes.map { UInt32($0 & 31) }
    }

    private static func convert(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var accumulator = 0, bits = 0
        var result: [UInt8] = []
        let maxValue = (1 << to) - 1
        for value in data {
            guard Int(value) >> from == 0 else { return nil }
            accumulator = (accumulator << from) | Int(value)
            bits += from
            while bits >= to { bits -= to; result.append(UInt8((accumulator >> bits) & maxValue)) }
        }
        if pad {
            if bits > 0 { result.append(UInt8((accumulator << (to - bits)) & maxValue)) }
        } else if bits >= from || ((accumulator << (to - bits)) & maxValue) != 0 {
            return nil
        }
        return result
    }

    public static func encode(hrp: String, data: Data) -> String {
        let words = convert(Array(data), from: 8, to: 5, pad: true)!.map(UInt32.init)
        let mod = polymod(expand(hrp) + words + [0, 0, 0, 0, 0, 0]) ^ 1
        let checksum = (0..<6).map { (mod >> (5 * (5 - UInt32($0)))) & 31 }
        return hrp + "1" + (words + checksum).map { String(alphabet[Int($0)]) }.joined()
    }

    /// Decodes and verifies the checksum. Mixed case is rejected, as BIP-173 requires.
    public static func decode(_ input: String) -> (hrp: String, data: Data)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == trimmed.lowercased() || trimmed == trimmed.uppercased() else { return nil }
        let value = trimmed.lowercased()
        guard value.count <= 90, let separator = value.lastIndex(of: "1") else { return nil }
        let hrp = String(value[..<separator])
        let payload = value[value.index(after: separator)...]
        guard !hrp.isEmpty, payload.count >= 6 else { return nil }
        var words: [UInt32] = []
        for character in payload {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            words.append(UInt32(index))
        }
        guard polymod(expand(hrp) + words) == 1 else { return nil }
        guard let bytes = convert(words.dropLast(6).map { UInt8($0) }, from: 5, to: 8, pad: false) else { return nil }
        return (hrp, Data(bytes))
    }
}

public enum NostrKeys {
    /// secp256k1 group order n; a valid secret scalar is in [1, n-1].
    static let order: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
                                 0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b, 0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41]

    public static func npub(publicKeyHex hex: String) -> String? {
        guard let data = Data(hex: hex), data.count == 32 else { return nil }
        return Bech32.encode(hrp: "npub", data: data)
    }

    public static func publicKeyHex(npub: String) -> String? {
        guard let decoded = Bech32.decode(npub), decoded.hrp == "npub", decoded.data.count == 32 else { return nil }
        return decoded.data.hex
    }

    public static func isValidNpub(_ value: String) -> Bool { publicKeyHex(npub: value) != nil && value == value.lowercased() }

    /// Returns the 32-byte scalar of a valid `nsec`, or nil.
    public static func secretKey(nsec: String) -> Data? {
        guard let decoded = Bech32.decode(nsec), decoded.hrp == "nsec", decoded.data.count == 32 else { return nil }
        let bytes = Array(decoded.data)
        guard bytes.contains(where: { $0 != 0 }), bytes.lexicographicallyPrecedes(order) else { return nil }
        return decoded.data
    }
}

extension Data {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    public init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
