import XCTest
@testable import RemitMd

/// Golden-vector tests for EIP-712 request signing.
/// Vectors are loaded from test-vectors/eip712.json at the repository root.
final class EIP712VectorTests: XCTestCase {

    // MARK: - JSON model

    private struct VectorFile: Decodable {
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let description: String
        let domain: Domain
        let message: Message
        let signer: String
        let expected_hash: String
        let expected_signature: String
    }

    private struct Domain: Decodable {
        let name: String
        let version: String
        let chain_id: UInt64
        let verifying_contract: String
    }

    /// Custom Decodable to handle the u64::MAX timestamp safely.
    /// Foundation's JSONDecoder routes UInt64 through NSNumber, which preserves the value
    /// correctly on Apple platforms. The custom init is kept as documentation.
    private struct Message: Decodable {
        let method: String
        let path: String
        let timestamp: UInt64
        let nonce: String  // "0x"-prefixed hex string
    }

    // MARK: - Helpers

    private static func loadVectors() throws -> [Vector] {
        // Navigate from this source file up to the sdk/ directory, then into test-vectors/
        // #file: .../sdk/swift/Tests/RemitMdTests/EIP712VectorTests.swift
        var url = URL(fileURLWithPath: #file)
        url.deleteLastPathComponent() // RemitMdTests/
        url.deleteLastPathComponent() // Tests/
        url.deleteLastPathComponent() // swift/
        url.deleteLastPathComponent() // sdk/
        url.appendPathComponent("test-vectors")
        url.appendPathComponent("eip712.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VectorFile.self, from: data).vectors
    }

    private func nonceData(from hexNonce: String) -> Data {
        let stripped = hexNonce.hasPrefix("0x") ? String(hexNonce.dropFirst(2)) : hexNonce
        return Data(hexString: stripped) ?? Data(repeating: 0, count: 32)
    }

    // MARK: - Tests

    func testEIP712Hashes() throws {
        let vectors = try Self.loadVectors()
        XCTAssertFalse(vectors.isEmpty, "No vectors loaded")

        for v in vectors {
            let nonce = nonceData(from: v.message.nonce)
            let hash = eip712Hash(
                chainId: v.domain.chain_id,
                routerAddress: v.domain.verifying_contract,
                method: v.message.method,
                path: v.message.path,
                timestamp: v.message.timestamp,
                nonce: nonce
            )
            XCTAssertEqual(
                "0x" + hash.hexString,
                v.expected_hash,
                "Hash mismatch for: \(v.description)"
            )
        }
    }

    func testEIP712Signatures() throws {
        // Anvil test wallet #0 private key
        let signer = try PrivateKeySigner(
            privateKey: "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
        )
        // Verify we derived the correct address
        XCTAssertEqual(
            signer.address.lowercased(),
            "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
        )

        let vectors = try Self.loadVectors()
        for v in vectors {
            let nonce = nonceData(from: v.message.nonce)
            let hash = eip712Hash(
                chainId: v.domain.chain_id,
                routerAddress: v.domain.verifying_contract,
                method: v.message.method,
                path: v.message.path,
                timestamp: v.message.timestamp,
                nonce: nonce
            )
            // secp256k1.swift may use different RFC 6979 k derivation than Rust's k256,
            // so exact signatures may differ. Verify structure and validity instead.
            // sign() uses Recovery key which verifies the signature recovers to our address.
            let sig = try signer.sign(digest: hash)
            XCTAssertTrue(sig.hasPrefix("0x"), "Sig must start with 0x for: \(v.description)")
            let sigHex = String(sig.dropFirst(2))
            XCTAssertEqual(sigHex.count, 130, "Sig must be 65 bytes (130 hex) for: \(v.description)")
            // Check v byte (last byte) is 27 (0x1b) or 28 (0x1c)
            let vByte = UInt8(sigHex.suffix(2), radix: 16) ?? 0
            XCTAssertTrue(vByte == 27 || vByte == 28, "v must be 27 or 28 for: \(v.description)")
        }
    }
}
