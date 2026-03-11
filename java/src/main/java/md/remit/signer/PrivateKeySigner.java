package md.remit.signer;

import md.remit.ErrorCodes;
import md.remit.RemitError;
import org.web3j.crypto.Credentials;
import org.web3j.crypto.ECDSASignature;
import org.web3j.crypto.Sign;
import org.web3j.utils.Numeric;

import java.math.BigInteger;

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
        // Sign the hash. ECKeyPair.sign() uses RFC-6979 deterministic k and normalises
        // s to low-s form via toCanonicalised(), which is required by the server's k256
        // verifier (Signature::from_slice rejects high-s signatures).
        ECDSASignature sig = credentials.getEcKeyPair().sign(hash);

        // Find the correct recovery ID (0 or 1) for the *canonicalized* signature.
        BigInteger publicKey = credentials.getEcKeyPair().getPublicKey();
        int recId = -1;
        for (int i = 0; i < 2; i++) {
            BigInteger recovered = Sign.recoverFromSignature(i, sig, hash);
            if (recovered != null && recovered.equals(publicKey)) {
                recId = i;
                break;
            }
        }
        if (recId == -1) {
            throw new RuntimeException(
                "Could not recover public key from signature — private key or hash may be invalid");
        }

        byte[] result = new byte[65];
        System.arraycopy(Numeric.toBytesPadded(sig.r, 32), 0, result, 0, 32);
        System.arraycopy(Numeric.toBytesPadded(sig.s, 32), 0, result, 32, 32);
        result[64] = (byte) (recId + 27);
        return result;
    }

    @Override
    public String address() {
        // credentials.getAddress() already returns "0x"-prefixed address (web3j Credentials stores
        // the address with Numeric.prependHexPrefix applied).  Do NOT prepend another "0x".
        return credentials.getAddress();
    }
}
