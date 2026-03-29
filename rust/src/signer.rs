use k256::ecdsa::{signature::hazmat::PrehashSigner, SigningKey};
use sha3::{Digest, Keccak256};

use crate::error::{codes, remit_err, remit_err_ctx, RemitError};

/// Signs EIP-712 typed data for authenticating API requests.
///
/// Implement this trait to use hardware wallets, KMS, or other signing backends.
/// For most agents, `PrivateKeySigner` is sufficient.
pub trait Signer: Send + Sync {
    /// Sign a 32-byte digest and return a 65-byte Ethereum signature (r, s, v).
    fn sign(&self, digest: &[u8; 32]) -> Result<Vec<u8>, RemitError>;

    /// Sign a 32-byte hash and return the 0x-prefixed hex signature (65 bytes: r+s+v).
    ///
    /// Used by `/permits/prepare` and `/x402/prepare` flows where the server
    /// computes the EIP-712 hash and the SDK only signs it.
    fn sign_hash(&self, hash: &[u8; 32]) -> Result<String, RemitError> {
        let sig_bytes = self.sign(hash)?;
        Ok(format!("0x{}", hex::encode(&sig_bytes)))
    }

    /// Return the Ethereum address (checksummed hex, `0x`-prefixed) for this key.
    fn address(&self) -> &str;
}

/// Signs API requests using an in-memory ECDSA private key.
///
/// The private key is held in memory and never logged or included in error messages.
/// For production agents, prefer a KMS-backed signer.
///
/// ```rust,ignore
/// use remitmd::PrivateKeySigner;
///
/// let signer = PrivateKeySigner::new("0xdeadbeef...")?;
/// println!("address: {}", signer.address());
/// ```
pub struct PrivateKeySigner {
    signing_key: SigningKey,
    address: String,
}

impl PrivateKeySigner {
    /// Create a signer from a hex-encoded private key (with or without `0x` prefix).
    pub fn new(hex_key: &str) -> Result<Self, RemitError> {
        let hex_key = hex_key.trim_start_matches("0x");
        let key_bytes = hex::decode(hex_key).map_err(|_| {
            remit_err_ctx(
                codes::INVALID_KEY,
                "invalid private key: expected 64 hex characters (32 bytes), optionally prefixed with 0x",
                "hint",
                "private keys are 64 hex characters, optionally prefixed with 0x",
            )
        })?;

        let signing_key = SigningKey::from_bytes(key_bytes.as_slice().into()).map_err(|e| {
            remit_err(
                codes::INVALID_KEY,
                format!("invalid private key: {e}. Key must be a valid 32-byte secp256k1 scalar."),
            )
        })?;

        let address = ethereum_address(signing_key.verifying_key());
        Ok(Self {
            signing_key,
            address,
        })
    }
}

impl Signer for PrivateKeySigner {
    fn sign(&self, digest: &[u8; 32]) -> Result<Vec<u8>, RemitError> {
        let (sig, recovery_id) = self
            .signing_key
            .sign_prehash(digest)
            .map_err(|e| remit_err(codes::INVALID_SIGNATURE, format!("signing failed: {e}")))?;

        let mut bytes = sig.to_bytes().to_vec(); // 64 bytes (r, s)
                                                 // Convert recovery_id to Ethereum's v (27 or 28)
        bytes.push(recovery_id.to_byte() + 27);
        Ok(bytes)
    }

    fn address(&self) -> &str {
        &self.address
    }
}

/// Derive the checksummed Ethereum address from a k256 verifying key.
fn ethereum_address(verifying_key: &k256::ecdsa::VerifyingKey) -> String {
    // Uncompressed public key: 0x04 || x (32) || y (32) = 65 bytes total
    let point = verifying_key.to_encoded_point(false);
    let pub_bytes = point.as_bytes();

    // Hash the 64-byte x||y (skipping 0x04 prefix)
    let mut hasher = Keccak256::new();
    hasher.update(&pub_bytes[1..]);
    let hash = hasher.finalize();

    // Last 20 bytes of the hash = Ethereum address
    let addr_bytes = &hash[12..];
    format!("0x{}", hex::encode(addr_bytes))
}
