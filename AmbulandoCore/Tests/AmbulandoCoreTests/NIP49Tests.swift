import XCTest
@testable import AmbulandoCore

/// NIP-49 against the official published vector, nostr-tools 2.24.2 (`nip49.encrypt`) output on SYNTHETIC keys, and an
/// independent noble (scrypt + xchacha20poly1305, fixed salt and nonce) known answer. No real identity is used anywhere.
final class NIP49Tests: XCTestCase {
    struct Vector { let name: String, key: String, password: String, logN: Int, security: Int, ncryptsec: String }

    static let official = "ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p"
    static let officialKey = "3501454135014541350145413501453fefb02227e449e57cf4d3a3ce05378683"

    static let nostrTools: [Vector] = [
        Vector(name: "synthetic-a", key: "0101010101010101010101010101010101010101010101010101010101010101", password: "correct horse battery", logN: 16, security: 1,
               ncryptsec: "ncryptsec1qggzcpwpyqpns6xxlj95j4p95qzdfty0qfygccc8jcftaxjun3mqd2q57l85wuw4unsqry7alhm4wfgyxavts9ezvv8cm7vwlw07fg2hxejysf04l2xnf08su2mllhyf58nzrcv05e9ttun5hu5smtuc"),
        Vector(name: "synthetic-b-nfkc", key: "0202020202020202020202020202020202020202020202020202020202020202", password: "\u{212B}\u{2126}\u{1E9B}\u{323}", logN: 12, security: 0,
               ncryptsec: "ncryptsec1qgx02kdw8vjhm53r020zn5ynyjc25ztjl5csk08v2pauxvu4zx4f6dfpuqz6t4ue845qp2jk9zxwssr0wypr2cjskxcc93wdszh50xfqds0822uqwye0m7hmjrrm69s2grhu2r2zzxkrg4uepq67g9hn"),
        Vector(name: "synthetic-c-untracked", key: "0a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728ff", password: "p4ss", logN: 10, security: 2,
               ncryptsec: "ncryptsec1qg9gzdm25v00s7lcn6xrcxn5d4wzhky0ex4lahk830ym46any9g4nd5ak2zfcrsa0cpsy0aqp3w4fgmrqp335nf4eftdemgq63ur9y3qv00ttdu67vk33jfhvqrqhgf3qx2m5mrpddssy80pngwz8uz9"),
    ]

    // Fixed salt 00..0f, nonce 40..57, password "swift deterministic", security 1; produced by noble, not by this code.
    static let knownKey3 = String(repeating: "03", count: 32)
    static let knownLogN11 = "ncryptsec1qg9sqqgzqvzq2ps8pqys5zcvp58q7szpgfp5g32xgayyjjjtf3x5un6s29f9x4z42etsr8nr0gmdx493awgeua02un2zr8nhzmk5ylrk5w8qa5j08fa0gtvjlt6r7y0rkmqlw5ztcjvwq2v5ey0wjn74"
    static let zeroScalar = "ncryptsec1qg9qqqgzqvzq2ps8pqys5zcvp58q7szpgfp5g32xgayyjjjtf3x5un6s29f9x4z42etsrx4xqrhkpknncxse79pqsxhkgrmd2fa8w07sz468ulmmp2qeamyc5rg3yszxeuwjs93ank69ur3q9583dhu6"
    static let orderScalar = "ncryptsec1qg9qqqgzqvzq2ps8pqys5zcvp58q7szpgfp5g32xgayyjjjtf3x5un6s29f9x4z42etsze2elugf7fvv8e0xp67l0egfhuwhljnfryyck48urtf9seg63twean405t6kzvqh02hhdtu0pnx4ns3eph9w"
    static let salt = Data((0..<16).map { UInt8($0) })
    static let nonce = Data((0..<24).map { UInt8(0x40 + $0) })

    private func payload(_ text: String) -> [UInt8] { Array(Bech32.decode(text, maxLength: 200)!.data) }
    private func encode(_ bytes: [UInt8]) -> String { Bech32.encode(hrp: "ncryptsec", data: Data(bytes)) }

    func testOfficialPublishedVector() throws {
        let opened = try NIP49.open(Self.official, password: "nostr")
        XCTAssertEqual(opened.secretKey.hex, Self.officialKey)
        XCTAssertEqual(payload(Self.official).count, 91)
        XCTAssertEqual(payload(Self.official)[1], 16)
        XCTAssertThrowsError(try NIP49.open(Self.official, password: "Nostr")) { XCTAssertEqual($0 as? NIP49Error, .wrongPasswordOrDamaged) }
    }

    func testNostrToolsOutputOpensIncludingNFKCAndSecurityByte() throws {
        for vector in Self.nostrTools {
            let opened = try NIP49.open(vector.ncryptsec, password: vector.password)
            XCTAssertEqual(opened.secretKey.hex, vector.key, vector.name)
            XCTAssertEqual(opened.keySecurity.rawValue, UInt8(vector.security), vector.name)
        }
    }

    func testPasswordIsNFKCNormalised() throws {
        let decomposed = "\u{212B}\u{2126}\u{1E9B}\u{0323}", composed = "\u{00C5}\u{03A9}\u{1E69}"
        let vector = Self.nostrTools[1]
        XCTAssertEqual(Array(composed.utf8), [0xC3, 0x85, 0xCE, 0xA9, 0xE1, 0xB9, 0xA9])
        XCTAssertEqual(Array(decomposed.precomposedStringWithCompatibilityMapping.utf8), Array(composed.utf8))
        XCTAssertEqual(try NIP49.open(vector.ncryptsec, password: decomposed).secretKey.hex, vector.key)
        XCTAssertEqual(try NIP49.open(vector.ncryptsec, password: composed).secretKey.hex, vector.key)
    }

    func testDeterministicSealMatchesIndependentImplementation() throws {
        let sealed = try NIP49.seal(secretKey: Data(hex: Self.knownKey3)!, password: "swift deterministic", logN: 11, keySecurity: .safe,
                                    salt: Self.salt, nonce: Self.nonce)
        XCTAssertEqual(sealed, Self.knownLogN11)
        XCTAssertEqual(try NIP49.open(Self.knownLogN11, password: "swift deterministic").secretKey.hex, Self.knownKey3)
    }

    func testRandomSealRoundTripShape() throws {
        let key = Data(hex: Self.knownKey3)!
        let a = try NIP49.seal(secretKey: key, password: "pw one", logN: 12)
        let b = try NIP49.seal(secretKey: key, password: "pw one", logN: 12)
        XCTAssertNotEqual(a, b, "fresh salt and nonce each time")
        let bytes = payload(a)
        XCTAssertEqual(bytes.count, 91)
        XCTAssertEqual(bytes[0], 2); XCTAssertEqual(bytes[1], 12); XCTAssertEqual(bytes[42], 1)
        XCTAssertNotEqual(Array(bytes[2..<18]), Array(payload(b)[2..<18]))
        XCTAssertTrue(a.hasPrefix("ncryptsec1"))
        let opened = try NIP49.open(a, password: "pw one")
        XCTAssertEqual(opened.secretKey, key)
        XCTAssertThrowsError(try NIP49.open(a, password: "pw two")) { XCTAssertEqual($0 as? NIP49Error, .wrongPasswordOrDamaged) }
    }

    func testAsyncWrappersRoundTrip() async throws {
        let key = Data(hex: Self.knownKey3)!
        let sealed = try await NIP49.encrypt(secretKey: key, password: "async pw", logN: 10)
        let opened = try await NIP49.decrypt(sealed, password: "async pw")
        XCTAssertEqual(opened.secretKey, key)
    }

    func testEveryByteTamperFails() throws {
        let vector = Self.nostrTools[2]   // logN 10: flipping the cost byte stays cheap
        let original = payload(vector.ncryptsec)
        XCTAssertEqual(original.count, 91)
        for index in 0..<original.count {
            var changed = original
            changed[index] ^= 0x01
            XCTAssertThrowsError(try NIP49.open(encode(changed), password: vector.password), "byte \(index)")
        }
    }

    func testBadChecksumAndStrings() {
        var chars = Array(Self.official)
        chars[40] = chars[40] == "q" ? "p" : "q"
        let cases: [String] = [String(chars), "", "ncryptsec1", "nsec1" + String(Self.official.dropFirst(10)), "garbage", String(Self.official.dropLast()),
                               "ncryptsec1" + String(Self.official.dropFirst(10).uppercased()) + "q"]
        for text in cases { XCTAssertThrowsError(try NIP49.open(text, password: "nostr"), text) }
        // Mixed case is not a bech32 string.
        XCTAssertThrowsError(try NIP49.open("NCRYPTSEC1" + String(Self.official.dropFirst(10)), password: "nostr"))
        // Upper case throughout is.
        XCTAssertEqual(try NIP49.open(Self.official.uppercased(), password: "nostr").secretKey.hex, Self.officialKey)
    }

    func testStructureValidation() {
        let good = payload(Self.nostrTools[2].ncryptsec)
        let pw = Self.nostrTools[2].password
        func code(_ bytes: [UInt8]) -> NIP49Error? {
            do { _ = try NIP49.open(encode(bytes), password: pw); return nil } catch { return error as? NIP49Error }
        }
        XCTAssertEqual(code(Array(good.dropLast())), .malformed)
        XCTAssertEqual(code(good + [0]), .malformed)
        XCTAssertEqual(code([]), .malformed)
        for version: UInt8 in [0, 1, 3, 255] { var b = good; b[0] = version; XCTAssertEqual(code(b), .unsupportedVersion, "version \(version)") }
        for log: UInt8 in [0, 1, 9, 19, 20, 21, 22, 40, 255] { var b = good; b[1] = log; XCTAssertEqual(code(b), .costOutOfRange, "logN \(log)") }
        for security: UInt8 in [3, 4, 255] { var b = good; b[42] = security; XCTAssertEqual(code(b), .malformed, "security \(security)") }
        var wrongSecurity = good; wrongSecurity[42] = 1   // valid byte, but not the one authenticated
        XCTAssertEqual(code(wrongSecurity), .wrongPasswordOrDamaged)
    }

    func testHighCostAndHugeInputRejectedBeforeAnyWork() {
        var heavy = payload(Self.nostrTools[2].ncryptsec); heavy[1] = 20   // 1 GiB if it were honoured
        let started = Date()
        XCTAssertThrowsError(try NIP49.open(encode(heavy), password: "x")) { XCTAssertEqual($0 as? NIP49Error, .costOutOfRange) }
        XCTAssertThrowsError(try NIP49.open(String(repeating: "q", count: 5_000_000), password: "x")) { XCTAssertEqual($0 as? NIP49Error, .malformed) }
        XCTAssertThrowsError(try NIP49.seal(secretKey: Data(hex: Self.knownKey3)!, password: "x", logN: 19)) { XCTAssertEqual($0 as? NIP49Error, .costOutOfRange) }
        XCTAssertThrowsError(try NIP49.seal(secretKey: Data(hex: Self.knownKey3)!, password: "x", logN: 9)) { XCTAssertEqual($0 as? NIP49Error, .costOutOfRange) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testDefaultsAndBoundsMatchTheHostedContract() throws {
        XCTAssertEqual(NIP49.defaultLogN, 16)
        XCTAssertEqual(NIP49.hostedMinLogN, 16)
        XCTAssertEqual(NIP49.maxLogN, 18)
        XCTAssertEqual(Self.official.count, 162, "hosted ncryptsec length")
        XCTAssertEqual(try NIP49.seal(secretKey: Data(hex: Self.knownKey3)!, password: "x", logN: 10).count, 162)
    }

    func testConcurrentKDFsAreSerialisedAndAllCorrect() async throws {
        let key = Data(hex: Self.knownKey3)!
        let backups = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<4 { group.addTask { (index, try await NIP49.encrypt(secretKey: key, password: "pw\(index)", logN: 10)) } }
            var out: [(Int, String)] = []
            for try await value in group { out.append(value) }
            return out
        }
        XCTAssertEqual(Set(backups.map(\.1)).count, 4)
        for (index, backup) in backups {
            let opened = try await NIP49.decrypt(backup, password: "pw\(index)")
            XCTAssertEqual(opened.secretKey, key)
        }
    }

    func testPasswordBounds() {
        let key = Data(hex: Self.knownKey3)!
        XCTAssertThrowsError(try NIP49.seal(secretKey: key, password: "", logN: 10)) { XCTAssertEqual($0 as? NIP49Error, .passwordRejected) }
        XCTAssertThrowsError(try NIP49.seal(secretKey: key, password: String(repeating: "a", count: 513), logN: 10)) { XCTAssertEqual($0 as? NIP49Error, .passwordRejected) }
        XCTAssertNoThrow(try NIP49.seal(secretKey: key, password: String(repeating: "a", count: 512), logN: 10))
        XCTAssertThrowsError(try NIP49.open(Self.nostrTools[2].ncryptsec, password: "")) { XCTAssertEqual($0 as? NIP49Error, .passwordRejected) }
    }

    func testInvalidScalarsAreRefusedOnBothSides() {
        for bad in [Data(count: 32), Data(NostrKeys.order), Data(repeating: 0xff, count: 32), Data(repeating: 1, count: 31)] {
            XCTAssertThrowsError(try NIP49.seal(secretKey: bad, password: "x", logN: 10)) { XCTAssertEqual($0 as? NIP49Error, .invalidKey) }
        }
        // Authentic ciphertexts (made by the independent implementation) that hold zero and the group order.
        for text in [Self.zeroScalar, Self.orderScalar] {
            XCTAssertThrowsError(try NIP49.open(text, password: "swift deterministic")) { XCTAssertEqual($0 as? NIP49Error, .invalidKey) }
        }
    }

    func testLongBech32DoesNotWidenNIP19() {
        XCTAssertNil(NostrKeys.secretKey(nsec: Self.official), "an ncryptsec is not an nsec")
        let long = Bech32.encode(hrp: "nsec", data: Data(repeating: 1, count: 80))
        XCTAssertNil(Bech32.decode(long), "default bound stays 90")
        XCTAssertNotNil(Bech32.decode(long, maxLength: 200))
    }
}
