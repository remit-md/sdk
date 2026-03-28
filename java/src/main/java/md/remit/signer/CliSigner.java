package md.remit.signer;

import md.remit.ErrorCodes;
import md.remit.RemitError;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HexFormat;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * Signs EIP-712 hashes by delegating to the {@code remit sign --digest} subprocess.
 *
 * <p>No key material enters this process — signing happens in a child process that
 * holds the encrypted keystore. This adapter only needs the CLI binary on PATH and
 * the {@code REMIT_KEY_PASSWORD} environment variable set.
 *
 * <p>The address is fetched and cached during construction via {@code remit address}.
 *
 * <pre>{@code
 * Signer signer = CliSigner.create();
 * Wallet wallet = RemitMd.withSigner(signer).build();
 * }</pre>
 */
public class CliSigner implements Signer {

    private static final long TIMEOUT_SECONDS = 10;

    private final String cliPath;
    private final String address;

    private CliSigner(String cliPath, String address) {
        this.cliPath = cliPath;
        this.address = address;
    }

    /**
     * Creates a CliSigner, fetching and caching the wallet address from the CLI.
     *
     * @param cliPath path to the remit CLI binary (default: "remit")
     * @return a fully initialized CliSigner
     * @throws RemitError if the CLI is not found, keystore is missing, or address is invalid
     */
    public static CliSigner create(String cliPath) {
        ProcessBuilder pb = new ProcessBuilder(cliPath, "address");
        pb.redirectErrorStream(false);

        Process process;
        try {
            process = pb.start();
        } catch (IOException e) {
            throw new RemitError(
                ErrorCodes.UNAUTHORIZED,
                "CliSigner: failed to start '" + cliPath + "': " + e.getMessage(),
                Map.of("hint", installHint())
            );
        }

        try {
            boolean finished = process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (!finished) {
                process.destroyForcibly();
                throw new RemitError(
                    ErrorCodes.SERVER_ERROR,
                    "CliSigner: '" + cliPath + " address' timed out after " + TIMEOUT_SECONDS + "s.",
                    Map.of()
                );
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            process.destroyForcibly();
            throw new RemitError(
                ErrorCodes.SERVER_ERROR,
                "CliSigner: interrupted while waiting for '" + cliPath + " address'.",
                Map.of()
            );
        }

        if (process.exitValue() != 0) {
            String stderr = readStream(process.getErrorStream());
            throw new RemitError(
                ErrorCodes.UNAUTHORIZED,
                "CliSigner: '" + cliPath + " address' failed: " + stderr,
                Map.of("exitCode", process.exitValue())
            );
        }

        String addr = readStream(process.getInputStream()).trim();
        if (!addr.startsWith("0x") || addr.length() != 42) {
            throw new RemitError(
                ErrorCodes.SERVER_ERROR,
                "CliSigner: invalid address from CLI: " + addr,
                Map.of()
            );
        }

        return new CliSigner(cliPath, addr);
    }

    /**
     * Creates a CliSigner using the default "remit" CLI path.
     *
     * @return a fully initialized CliSigner
     * @throws RemitError if the CLI is not found, keystore is missing, or address is invalid
     */
    public static CliSigner create() {
        return create("remit");
    }

    @Override
    public byte[] sign(byte[] hash) {
        if (hash == null || hash.length != 32) {
            throw new RemitError(
                ErrorCodes.INVALID_PARAM,
                "CliSigner: hash must be exactly 32 bytes.",
                Map.of("length", hash == null ? 0 : hash.length)
            );
        }

        String hexDigest = "0x" + HexFormat.of().formatHex(hash);

        ProcessBuilder pb = new ProcessBuilder(cliPath, "sign", "--digest");
        pb.redirectErrorStream(false);

        Process process;
        try {
            process = pb.start();
        } catch (IOException e) {
            throw new RemitError(
                ErrorCodes.SERVER_ERROR,
                "CliSigner: failed to start '" + cliPath + " sign --digest': " + e.getMessage(),
                Map.of()
            );
        }

        // Write hex digest to stdin, then CLOSE the stream (Java gotcha G1)
        try {
            OutputStream stdin = process.getOutputStream();
            stdin.write(hexDigest.getBytes(StandardCharsets.UTF_8));
            stdin.flush();
            stdin.close();
        } catch (IOException e) {
            process.destroyForcibly();
            throw new RemitError(
                ErrorCodes.SERVER_ERROR,
                "CliSigner: failed to write to stdin: " + e.getMessage(),
                Map.of()
            );
        }

        try {
            boolean finished = process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (!finished) {
                process.destroyForcibly();
                throw new RemitError(
                    ErrorCodes.SERVER_ERROR,
                    "CliSigner: '" + cliPath + " sign --digest' timed out after " + TIMEOUT_SECONDS + "s.",
                    Map.of()
                );
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            process.destroyForcibly();
            throw new RemitError(
                ErrorCodes.SERVER_ERROR,
                "CliSigner: interrupted while waiting for signing.",
                Map.of()
            );
        }

        if (process.exitValue() != 0) {
            String stderr = readStream(process.getErrorStream());
            throw new RemitError(
                ErrorCodes.UNAUTHORIZED,
                "CliSigner: signing failed: " + stderr,
                Map.of("exitCode", process.exitValue())
            );
        }

        String sig = readStream(process.getInputStream()).trim();
        if (sig.isEmpty()) {
            throw new RemitError(
                ErrorCodes.SERVER_ERROR,
                "CliSigner: CLI returned empty signature.",
                Map.of()
            );
        }

        return parseHexSignature(sig);
    }

    @Override
    public String address() {
        return address;
    }

    /**
     * Checks whether the CLI signer can be activated.
     * <p>Detection order:
     * <ol>
     *   <li>CLI binary found on PATH (or at the given path)</li>
     *   <li>{@code ~/.remit/keys/default.meta} exists (keychain-backed, no password needed)</li>
     *   <li>{@code ~/.remit/keys/default.enc} exists AND {@code REMIT_KEY_PASSWORD} is set</li>
     * </ol>
     *
     * @return true if the CLI signer can be activated
     */
    public static boolean isAvailable() {
        return isAvailable("remit");
    }

    /**
     * Checks whether the CLI signer can be activated with the given CLI path.
     *
     * @param cliPath path to the remit CLI binary
     * @return true if the CLI signer can be activated
     */
    public static boolean isAvailable(String cliPath) {
        // 1. Check CLI on PATH
        try {
            ProcessBuilder pb = new ProcessBuilder(cliPath, "address");
            pb.redirectErrorStream(true);
            Process process = pb.start();
            boolean finished = process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (!finished) {
                process.destroyForcibly();
                return false;
            }
            if (process.exitValue() != 0) {
                return false;
            }
        } catch (IOException | InterruptedException e) {
            return false;
        }

        Path keysDir = Path.of(System.getProperty("user.home"), ".remit", "keys");

        // 2. Keychain meta file (no password needed)
        if (Files.exists(keysDir.resolve("default.meta"))) {
            return true;
        }

        // 3. Encrypted keystore + password
        if (Files.exists(keysDir.resolve("default.enc"))) {
            String password = System.getenv("REMIT_KEY_PASSWORD");
            return password != null && !password.isEmpty();
        }

        return false;
    }

    @Override
    public String toString() {
        return "CliSigner{address=" + address + "}";
    }

    // ─── Internal ────────────────────────────────────────────────────────────────

    private static String readStream(java.io.InputStream stream) {
        try {
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return "";
        }
    }

    private static byte[] parseHexSignature(String hex) {
        String clean = hex.startsWith("0x") ? hex.substring(2) : hex;
        try {
            byte[] bytes = HexFormat.of().parseHex(clean);
            if (bytes.length != 65) {
                throw new RemitError(
                    ErrorCodes.SERVER_ERROR,
                    "CliSigner: expected 65-byte signature, got " + bytes.length + " bytes.",
                    Map.of("length", bytes.length)
                );
            }
            return bytes;
        } catch (IllegalArgumentException e) {
            throw new RemitError(
                ErrorCodes.SERVER_ERROR,
                "CliSigner: CLI returned malformed signature hex.",
                Map.of()
            );
        }
    }

    private static String installHint() {
        String os = System.getProperty("os.name", "").toLowerCase();
        if (os.contains("mac")) {
            return "Install: brew install remit-md/tap/remit";
        } else if (os.contains("win")) {
            return "Install: winget install remit-md.remit";
        } else {
            return "Install: curl -fsSL https://remit.md/install.sh | sh";
        }
    }
}
