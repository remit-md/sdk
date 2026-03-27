package md.remit;

import md.remit.internal.ApiClient;
import md.remit.signer.CliSigner;
import md.remit.signer.PrivateKeySigner;
import md.remit.signer.Signer;

import java.util.Map;

/**
 * Entry point for creating {@link Wallet} instances.
 *
 * <p><b>From environment variables (recommended):</b>
 * <pre>{@code
 * Wallet wallet = RemitMd.fromEnv();
 * // Reads REMITMD_KEY, REMITMD_CHAIN, REMITMD_TESTNET, REMITMD_ROUTER_ADDRESS
 * }</pre>
 *
 * <p><b>With explicit key:</b>
 * <pre>{@code
 * Wallet wallet = RemitMd.withKey("0x...").build();
 * }</pre>
 *
 * <p><b>For testing:</b>
 * <pre>{@code
 * MockRemit mock = new MockRemit();
 * Wallet wallet = mock.wallet(); // no key needed
 * }</pre>
 */
public final class RemitMd {

    // API endpoints per chain
    private static final Map<String, String> API_URLS = Map.of(
        "base",           "https://remit.md",
        "base-sepolia",   "https://testnet.remit.md",
        "localhost",      "http://localhost:3000"
    );

    private static final Map<String, Long> CHAIN_IDS = Map.of(
        "base",           8453L,
        "base-sepolia",   84532L,
        "localhost",      31337L
    );

    private RemitMd() {}

    /**
     * Creates a Wallet from environment variables.
     *
     * <p>Signing credential priority:
     * <ol>
     *   <li>{@code remit} CLI (CliSigner) - if CLI on PATH, keystore exists, password set</li>
     *   <li>{@code REMITMD_KEY} - hex-encoded private key</li>
     * </ol>
     *
     * <p>Additional options:
     * <ul>
     *   <li>{@code REMITMD_CHAIN} - chain name, default "base" (only "base" supported)</li>
     *   <li>{@code REMITMD_TESTNET} - "1", "true", or "yes" for testnet</li>
     *   <li>{@code REMITMD_ROUTER_ADDRESS} - EIP-712 verifying contract address</li>
     * </ul>
     *
     * @throws RemitError if no signing credentials are set or are malformed
     */
    public static Wallet fromEnv() {
        Builder b;

        // Priority: CliSigner > REMITMD_KEY > error
        if (CliSigner.isAvailable()) {
            b = withSigner(CliSigner.create());
        } else {
            String key = System.getenv("REMITMD_KEY");
            if (key == null || key.isBlank()) {
                String os = System.getProperty("os.name", "").toLowerCase();
                String installCmd;
                if (os.contains("mac")) {
                    installCmd = "brew install remit-md/tap/remit";
                } else if (os.contains("win")) {
                    installCmd = "winget install remit-md.remit";
                } else {
                    installCmd = "curl -fsSL https://remit.md/install.sh | sh";
                }
                throw new RemitError(ErrorCodes.UNAUTHORIZED,
                    "No signing credentials found. Install the remit CLI or set REMITMD_KEY.",
                    Map.of("hint", installCmd)
                );
            }
            b = withKey(key);
        }

        String chain = System.getenv("REMITMD_CHAIN");
        if (chain != null && !chain.isBlank()) b = b.chain(chain);
        String testnet = System.getenv("REMITMD_TESTNET");
        if ("1".equals(testnet) || "true".equalsIgnoreCase(testnet) || "yes".equalsIgnoreCase(testnet)) {
            b = b.testnet(true);
        }
        String routerAddress = System.getenv("REMITMD_ROUTER_ADDRESS");
        if (routerAddress != null && !routerAddress.isBlank()) b = b.routerAddress(routerAddress);
        return b.build();
    }

    /** Creates a builder with a hex-encoded private key. */
    public static Builder withKey(String privateKey) {
        return new Builder(new PrivateKeySigner(privateKey));
    }

    /** Creates a builder with a custom {@link Signer} (e.g., KMS-backed). */
    public static Builder withSigner(Signer signer) {
        return new Builder(signer);
    }

    /** Builder for constructing {@link Wallet} instances. */
    public static class Builder {
        private final Signer signer;
        private String chain = "base";
        private boolean testnet = false;
        private String baseUrl = null;
        private String routerAddress = null;

        private Builder(Signer signer) {
            this.signer = signer;
        }

        /** Sets the target chain. Supported: "base". Default: "base". */
        public Builder chain(String chain) {
            this.chain = chain;
            return this;
        }

        /** Targets the testnet version of the selected chain. */
        public Builder testnet(boolean testnet) {
            this.testnet = testnet;
            return this;
        }

        /** Overrides the API base URL (for self-hosted or local testing). */
        public Builder baseUrl(String url) {
            this.baseUrl = url;
            return this;
        }

        /** Sets the EIP-712 verifying contract address (router). Required for production use. */
        public Builder routerAddress(String addr) {
            this.routerAddress = addr;
            return this;
        }

        /** Builds the {@link Wallet}. */
        public Wallet build() {
            String chainKey = "localhost".equals(chain) ? "localhost" : (testnet ? chain + "-sepolia" : chain);
            if (!API_URLS.containsKey(chainKey)) {
                throw new RemitError(ErrorCodes.INVALID_CHAIN,
                    "Unsupported chain \"" + chain + "\". Valid chains: base. " +
                    "For testnet, call .testnet(true).",
                    Map.of("chain", chain)
                );
            }
            String envUrl = System.getenv("REMITMD_API_URL");
            String apiUrl = baseUrl != null ? baseUrl : (envUrl != null && !envUrl.isBlank() ? envUrl : API_URLS.get(chainKey));
            long chainId = CHAIN_IDS.get(chainKey);
            ApiClient client = new ApiClient(apiUrl, chainId, routerAddress, signer);
            return new Wallet(client, signer, chainId, chainKey);
        }
    }
}
