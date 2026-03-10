import Foundation
@preconcurrency import secp256k1

// MARK: - Signer protocol

/// Signs EIP-712 typed data and Ethereum personal messages.
/// Inject a ``MockSigner`` in tests; use ``PrivateKeySigner`` in production.
public protocol Signer: Sendable {
    var address: String { get }

    /// Sign a 32-byte digest and return a 65-byte hex-encoded ECDSA signature (r+s+v).
    func sign(digest: Data) throws -> String
}

// MARK: - PrivateKeySigner

/// Production signer backed by a secp256k1 private key.
///
/// The Ethereum address is derived from the public key via keccak256 (address = keccak256(pubkey)[12:]).
///
/// ```swift
/// let signer = try PrivateKeySigner(privateKey: "0x...")
/// print(signer.address) // "0x..."
/// ```
public final class PrivateKeySigner: Signer {
    public let address: String
    private let privateKey: secp256k1.Recovery.PrivateKey

    /// - Parameter privateKey: 32-byte hex private key (with or without 0x prefix).
    public init(privateKey hex: String) throws {
        let stripped = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard stripped.count == 64, let keyData = Data(hexString: stripped) else {
            throw RemitError(
                RemitError.signatureInvalid,
                "private key must be 64 hex chars (32 bytes), got \(stripped.count) chars"
            )
        }
        let key = try secp256k1.Recovery.PrivateKey(dataRepresentation: keyData)
        self.privateKey = key
        self.address = PrivateKeySigner.deriveAddress(compressedPubKey: key.publicKey.dataRepresentation)
    }

    /// Sign a 32-byte EIP-712 digest using ECDSA, returning hex-encoded 65-byte signature (r+s+v).
    /// v is 0x1b (27) or 0x1c (28) per Ethereum convention.
    public func sign(digest: Data) throws -> String {
        guard digest.count == 32 else {
            throw RemitError(
                RemitError.signatureInvalid,
                "digest must be exactly 32 bytes, got \(digest.count)"
            )
        }
        let sig = try privateKey.signature(for: digest)
        // dataRepresentation is 65 bytes: r(32) || s(32) || recid(1)
        let sigData = sig.dataRepresentation
        var result = Data(sigData.prefix(64))
        result.append(sigData[64] + 27)  // v = 27 or 28
        return "0x" + result.hexString
    }

    // MARK: - Ethereum address derivation from 33-byte compressed public key

    /// Decompress the public key, compute keccak256 over the 64-byte X||Y, and
    /// take the last 20 bytes as the Ethereum address.
    internal static func deriveAddress(compressedPubKey bytes: Data) -> String {
        guard bytes.count == 33 else { return zeroAddress }
        let prefix  = bytes[0]           // 0x02 = even y, 0x03 = odd y
        let xBytes  = Array(bytes[1...]) // 32-byte x coordinate

        guard let yBytes = decompressY(x: xBytes, evenY: prefix == 0x02) else {
            return zeroAddress
        }
        var raw = Data(xBytes)
        raw.append(contentsOf: yBytes)
        let hash = keccak256(raw)
        return "0x" + hash.suffix(20).hexString
    }

    private static let zeroAddress = "0x" + String(repeating: "00", count: 40)
}

// MARK: - secp256k1 y-coordinate recovery

/// Recover the y-coordinate given x and the parity of y.
/// secp256k1: y² ≡ x³ + 7 (mod p)
/// Since p ≡ 3 (mod 4): y = (x³ + 7)^((p+1)/4) mod p
private func decompressY(x: [UInt8], evenY: Bool) -> [UInt8]? {
    guard x.count == 32 else { return nil }

    // secp256k1 field prime p (big-endian)
    let p: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFE, 0xFF, 0xFF, 0xFC, 0x2F,
    ]
    // (p + 1) / 4 — the square root exponent for p ≡ 3 (mod 4)
    let sqrtExp: [UInt8] = [
        0x3F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xBF, 0xFF, 0xFF, 0x0C,
    ]
    let seven: [UInt8] = [UInt8](repeating: 0, count: 31) + [7]

    // x³ + 7 mod p
    let x2  = mulmod(x, x, p)
    let x3  = mulmod(x2, x, p)
    let rhs = addmod(x3, seven, p)

    // y = rhs^((p+1)/4) mod p
    var y = powmod(rhs, sqrtExp, p)

    // Adjust parity (even/odd of last byte)
    let isEven = (y.last! & 1) == 0
    if isEven != evenY {
        y = submod(p, y, p) // negate: y = p - y
    }
    return y
}

// MARK: - 256-bit modular arithmetic (big-endian byte arrays)

/// (a + b) mod m — assumes a,b < m
private func addmod(_ a: [UInt8], _ b: [UInt8], _ m: [UInt8]) -> [UInt8] {
    let s = add256(a, b)
    return cmp256(s, m) >= 0 ? sub256(s, m) : s
}

/// (a - b) mod m — assumes a,b < m
private func submod(_ a: [UInt8], _ b: [UInt8], _ m: [UInt8]) -> [UInt8] {
    return cmp256(a, b) >= 0 ? sub256(a, b) : sub256(add256(a, m), b)
}

/// (a * b) mod m — double-and-add scanning bits of b from MSB
private func mulmod(_ a: [UInt8], _ b: [UInt8], _ m: [UInt8]) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 32)
    for i in 0..<32 {
        for j in (0..<8).reversed() {
            r = addmod(r, r, m)                   // r = 2r mod m
            if (b[i] >> j) & 1 == 1 {
                r = addmod(r, a, m)               // r = r + a mod m
            }
        }
    }
    return r
}

/// (base^exp) mod m — square-and-multiply scanning bits of exp from MSB
private func powmod(_ base: [UInt8], _ exp: [UInt8], _ m: [UInt8]) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 31) + [1] // r = 1
    for i in 0..<32 {
        for j in (0..<8).reversed() {
            r = mulmod(r, r, m)                    // r = r² mod m
            if (exp[i] >> j) & 1 == 1 {
                r = mulmod(r, base, m)             // r = r * base mod m
            }
        }
    }
    return r
}

// MARK: - Raw 256-bit arithmetic (no modular reduction, big-endian)

private func add256(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: 32)
    var carry: UInt16 = 0
    for i in (0..<32).reversed() {
        let s = UInt16(a[i]) + UInt16(b[i]) + carry
        result[i] = UInt8(s & 0xFF)
        carry = s >> 8
    }
    return result
}

private func sub256(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: 32)
    var borrow: Int = 0
    for i in (0..<32).reversed() {
        let d = Int(a[i]) - Int(b[i]) - borrow
        result[i] = UInt8(bitPattern: Int8(truncatingIfNeeded: d))
        borrow = d < 0 ? 1 : 0
    }
    return result
}

/// Lexicographic compare — returns -1, 0, or 1.
private func cmp256(_ a: [UInt8], _ b: [UInt8]) -> Int {
    for i in 0..<32 {
        if a[i] < b[i] { return -1 }
        if a[i] > b[i] { return  1 }
    }
    return 0
}

// MARK: - MockSigner (for tests)

/// Deterministic mock signer — returns a fixed address and zero-filled signature.
/// Safe to use in tests without any cryptographic setup.
public final class MockSigner: Signer, @unchecked Sendable {
    public let address: String

    public init(address: String = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266") {
        self.address = address
    }

    public func sign(digest _: Data) throws -> String {
        // 65-byte zero signature — accepted by MockTransport, rejected by real contracts
        return "0x" + String(repeating: "00", count: 130)
    }
}

// MARK: - Data hex helpers

extension Data {
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
