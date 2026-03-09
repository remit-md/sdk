package md.remit.signer;

import md.remit.ErrorCodes;
import md.remit.RemitError;
import org.web3j.crypto.Credentials;
import org.web3j.crypto.Keys;
import org.web3j.crypto.Sign;
import org.web3j.utils.Numeric;

import java.math.BigInteger;
import java.nio.ByteBuffer;

/**
 * Signs EIP-712 hashes using an in-process Ethereum private key.
 *
 * <p>The private key is stored in memory but never logged or included in
 * exception messages.
 */
public class PrivateKeySigner implements Signer {

    private final Credentials credentials;

    /**
     * @param hexPrivateKey hex-encoded private key, with or without 0x prefix
     * @throws RemitError if the key is malformed
     */
    public PrivateKeySigner(String hexPrivateKey) {
        if (hexPrivateKey == null || hexPrivateKey.isBlank()) {
            throw new RemitError(
                ErrorCodes.UNAUTHORIZED,
                "Private key is required. Set REMITMD_KEY or pass the key directly.",
                java.util.Map.of("hint", "export REMITMD_KEY=0x...")
            );
        }
        try {
            String clean = hexPrivateKey.startsWith("0x")
                ? hexPrivateKey.substring(2)
                : hexPrivateKey;
            this.credentials = Credentials.create(clean);
        } catch (Exception e) {
            throw new RemitError(
                ErrorCodes.UNAUTHORIZED,
                "Invalid private key format: expected 64-character hex string. [key redacted]",
                java.util.Map.of()
            );
        }
    }

    @Override
    public byte[] sign(byte[] hash) {
        Sign.SignatureData sig = Sign.signMessage(hash, credentials.getEcKeyPair(), false);
        // Pack into 65-byte r+s+v format
        byte[] result = new byte[65];
        System.arraycopy(sig.getR(), 0, result, 0, 32);
        System.arraycopy(sig.getS(), 0, result, 32, 32);
        result[64] = sig.getV()[0];
        return result;
    }

    @Override
    public String address() {
        return "0x" + credentials.getAddress();
    }
}
