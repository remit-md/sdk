import Foundation

/// Signer backed by the `remit` CLI binary.
///
/// Delegates EIP-712 signing to a `remit sign --digest` subprocess. The CLI
/// holds the encrypted keystore; this adapter only needs the binary on PATH
/// and the `REMIT_SIGNER_KEY` env var set.
///
/// - No key material in this process -- signing happens in a subprocess.
/// - Address is cached at construction time via `remit address`.
/// - `sign(digest:)` pipes hex to `remit sign --digest` on stdin.
/// - All errors are explicit -- no silent fallbacks.
///
/// ```swift
/// let signer = try CliSigner()
/// let wallet = RemitWallet(signer: signer, chain: .base)
/// ```
public final class CliSigner: Signer, @unchecked Sendable {
    public let address: String

    private let cliPath: String

    /// Timeout in seconds for CLI subprocess calls.
    private static let cliTimeout: TimeInterval = 10

    // MARK: - Init

    /// Create a CliSigner, fetching and caching the wallet address via `remit address`.
    ///
    /// - Parameter cliPath: Path to the `remit` binary (default: `"remit"`).
    /// - Throws: `RemitError` if the CLI is not found, keystore missing, or returns invalid address.
    public init(cliPath: String = "remit") throws {
        self.cliPath = cliPath

        let (stdout, stderr, exitCode) = CliSigner.run(
            cliPath: cliPath,
            arguments: ["address"],
            stdin: nil
        )

        guard exitCode == 0 else {
            throw RemitError(RemitError.unauthorized,
                "CliSigner: failed to get address: \(stderr)")
        }

        let addr = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addr.hasPrefix("0x"), addr.count == 42 else {
            throw RemitError(RemitError.unauthorized,
                "CliSigner: invalid address from CLI: \(addr)")
        }

        self.address = addr
    }

    // MARK: - Signer protocol

    /// Sign a 32-byte digest by piping its hex representation to `remit sign --digest` on stdin.
    ///
    /// - Parameter digest: 32-byte EIP-712 digest.
    /// - Returns: Hex-encoded 65-byte ECDSA signature (r+s+v).
    /// - Throws: `RemitError` on CLI errors or invalid output.
    public func sign(digest: Data) throws -> String {
        let digestHex = "0x" + digest.hexString

        let (stdout, stderr, exitCode) = CliSigner.run(
            cliPath: cliPath,
            arguments: ["sign", "--digest"],
            stdin: digestHex
        )

        guard exitCode == 0 else {
            throw RemitError(RemitError.invalidSignature,
                "CliSigner: signing failed: \(stderr)")
        }

        let sig = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sig.hasPrefix("0x"), sig.count == 132 else {
            throw RemitError(RemitError.invalidSignature,
                "CliSigner: invalid signature from CLI: \(sig)")
        }

        return sig
    }

    // MARK: - Availability check

    /// Check conditions for CliSigner activation:
    /// 1. CLI binary found (runs `remit --version` successfully)
    /// 2. Meta file at `~/.remit/keys/default.meta` (keychain -- no password needed), OR
    /// 3. Keystore file at `~/.remit/keys/default.enc` AND `REMIT_SIGNER_KEY` env var set
    ///
    /// - Parameter cliPath: Path to the `remit` binary (default: `"remit"`).
    /// - Returns: `true` if CLI exists and either keychain meta or encrypted keystore + password are available.
    public static func isAvailable(cliPath: String = "remit") -> Bool {
        // 1. CLI binary exists and runs
        let (_, _, exitCode) = run(cliPath: cliPath, arguments: ["--version"], stdin: nil)
        guard exitCode == 0 else { return false }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let keysDir = home + "/.remit/keys"
        let fm = FileManager.default

        // 2. Keychain meta file -- no password needed
        if fm.fileExists(atPath: keysDir + "/default.meta") {
            return true
        }

        // 3. Encrypted keystore + password
        guard fm.fileExists(atPath: keysDir + "/default.enc") else { return false }

        guard let password = ProcessInfo.processInfo.environment["REMIT_SIGNER_KEY"] ?? ProcessInfo.processInfo.environment["REMIT_KEY_PASSWORD"],
              !password.isEmpty else {
            return false
        }

        return true
    }

    // MARK: - Subprocess helper

    /// Run a CLI command synchronously and return (stdout, stderr, exitCode).
    ///
    /// GOTCHA G1: Must close the stdin pipe write end before reading stdout,
    /// otherwise the subprocess may block waiting for more input.
    private static func run(
        cliPath: String,
        arguments: [String],
        stdin stdinData: String?
    ) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [cliPath] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let input = stdinData {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            do {
                try process.run()
            } catch {
                return ("", "CliSigner: failed to launch \(cliPath): \(error.localizedDescription)", 1)
            }
            // Write input data, then CLOSE the write end (GOTCHA G1)
            stdinPipe.fileHandleForWriting.write(Data(input.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        } else {
            do {
                try process.run()
            } catch {
                return ("", "CliSigner: failed to launch \(cliPath): \(error.localizedDescription)", 1)
            }
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (stdout, stderr, process.terminationStatus)
    }
}
