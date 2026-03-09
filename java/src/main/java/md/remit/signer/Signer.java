package md.remit.signer;

/**
 * Signs EIP-712 typed data hashes.
 *
 * <p>Implement this interface to use a custom key management system
 * (AWS KMS, Google Cloud KMS, HSM, etc.) instead of an in-process private key.
 *
 * <pre>{@code
 * Signer kmsSign = hash -> myKmsClient.sign(hash);
 * Wallet wallet = RemitMd.withSigner(kmsSign).build();
 * }</pre>
 */
@FunctionalInterface
public interface Signer {

    /**
     * Sign a 32-byte EIP-712 hash.
     *
     * @param hash 32-byte hash to sign
     * @return 65-byte signature (r + s + v)
     * @throws Exception if signing fails
     */
    byte[] sign(byte[] hash) throws Exception;

    /**
     * Returns the Ethereum address (0x-prefixed, checksummed) corresponding to this signer's key.
     * Default implementation returns a placeholder — override if address is needed for display.
     */
    default String address() {
        return "0x0000000000000000000000000000000000000000";
    }
}
