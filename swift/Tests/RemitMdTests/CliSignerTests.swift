import XCTest
import Foundation
@testable import RemitMd

// MARK: - CliSigner tests

/// Tests for CliSigner.
///
/// These tests exercise CliSigner's behavior with a mock CLI script.
/// Since CliSigner shells out to a subprocess, we create small bash scripts
/// that simulate the `remit` binary's behavior.
final class CliSignerTests: XCTestCase {

    /// Directory for temporary mock scripts.
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "remit-cli-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(atPath: dir)
        }
        super.tearDown()
    }

    /// Write a mock CLI script that echoes a fixed address for `address`
    /// and a fixed signature for `sign --digest`.
    private func writeMockCli(
        address: String = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
        signature: String = "0x" + String(repeating: "ab", count: 32)
            + String(repeating: "cd", count: 32) + "1b",
        addressExitCode: Int = 0,
        signExitCode: Int = 0,
        versionExitCode: Int = 0
    ) -> String {
        let scriptPath = tempDir + "/remit"
        let script = """
        #!/bin/bash
        if [ "$1" = "address" ]; then
            echo "\(address)"
            exit \(addressExitCode)
        elif [ "$1" = "sign" ] && [ "$2" = "--digest" ]; then
            # Read stdin (the digest hex)
            read -r digest_hex
            echo "\(signature)"
            exit \(signExitCode)
        elif [ "$1" = "--version" ]; then
            echo "remit 0.1.0"
            exit \(versionExitCode)
        else
            echo "unknown command: $1" >&2
            exit 1
        fi
        """
        try! script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        // Make executable
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptPath
        )
        return scriptPath
    }

    // MARK: - Happy path

    func testCreateAndSign() throws {
        #if os(Windows)
        throw XCTSkip("CliSigner uses Unix Process, skip on Windows")
        #endif

        let mockCli = writeMockCli()
        let signer = try CliSigner(cliPath: mockCli)
        XCTAssertEqual(signer.address, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

        let digest = Data(repeating: 0x42, count: 32)
        let sig = try signer.sign(digest: digest)
        let expected = "0x" + String(repeating: "ab", count: 32)
            + String(repeating: "cd", count: 32) + "1b"
        XCTAssertEqual(sig, expected)
    }

    // MARK: - Address command fails

    func testAddressFailure() throws {
        #if os(Windows)
        throw XCTSkip("CliSigner uses Unix Process, skip on Windows")
        #endif

        let scriptPath = tempDir + "/remit"
        let script = """
        #!/bin/bash
        if [ "$1" = "address" ]; then
            echo "keystore not found" >&2
            exit 1
        fi
        """
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptPath
        )

        do {
            _ = try CliSigner(cliPath: scriptPath)
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.unauthorized)
            XCTAssertTrue(e.message.contains("failed to get address"))
        }
    }

    // MARK: - Invalid address format

    func testInvalidAddressFormat() throws {
        #if os(Windows)
        throw XCTSkip("CliSigner uses Unix Process, skip on Windows")
        #endif

        let mockCli = writeMockCli(address: "not-an-address")

        do {
            _ = try CliSigner(cliPath: mockCli)
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.unauthorized)
            XCTAssertTrue(e.message.contains("invalid address"))
        }
    }

    // MARK: - Sign command fails

    func testSignFailure() throws {
        #if os(Windows)
        throw XCTSkip("CliSigner uses Unix Process, skip on Windows")
        #endif

        // Script that succeeds for address but fails for sign
        let scriptPath = tempDir + "/remit"
        let script = """
        #!/bin/bash
        if [ "$1" = "address" ]; then
            echo "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
            exit 0
        elif [ "$1" = "sign" ]; then
            echo "decryption failed" >&2
            exit 1
        fi
        """
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptPath
        )

        let signer = try CliSigner(cliPath: scriptPath)
        XCTAssertEqual(signer.address, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

        do {
            _ = try signer.sign(digest: Data(repeating: 0, count: 32))
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.invalidSignature)
            XCTAssertTrue(e.message.contains("signing failed"))
        }
    }

    // MARK: - Invalid signature format

    func testInvalidSignatureFormat() throws {
        #if os(Windows)
        throw XCTSkip("CliSigner uses Unix Process, skip on Windows")
        #endif

        let mockCli = writeMockCli(signature: "bad-signature")
        let signer = try CliSigner(cliPath: mockCli)

        do {
            _ = try signer.sign(digest: Data(repeating: 0, count: 32))
            XCTFail("Expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.invalidSignature)
            XCTAssertTrue(e.message.contains("invalid signature"))
        }
    }

    // MARK: - CLI not found

    func testCliNotFound() throws {
        do {
            _ = try CliSigner(cliPath: "/nonexistent/path/remit")
            XCTFail("Expected error")
        } catch {
            // Expected -- either RemitError or a launch failure
        }
    }

    // MARK: - isAvailable returns false when CLI missing

    func testIsAvailableFalseWhenCliMissing() {
        let result = CliSigner.isAvailable(cliPath: "/nonexistent/path/remit")
        XCTAssertFalse(result)
    }
}
