using System.Text;
using Nethereum.Signer;
using Nethereum.Util;

namespace RemitMd;

/// <summary>
/// Signs EIP-712 payment messages on behalf of a wallet.
/// Implement this interface to use hardware wallets, KMS, or HSMs.
/// </summary>
public interface IRemitSigner
{
    /// <summary>The Ethereum address corresponding to this signer's key.</summary>
    string Address { get; }

    /// <summary>Signs an EIP-712 structured data hash and returns a hex-encoded signature.</summary>
    string Sign(byte[] hash);
}

/// <summary>
/// ECDSA signer backed by a raw secp256k1 private key.
/// Suitable for agents running in trusted environments with key isolation.
/// </summary>
public sealed class PrivateKeySigner : IRemitSigner
{
    private readonly EthECKey _key;

    /// <summary>Creates a signer from a hex-encoded private key (with or without 0x prefix).</summary>
    /// <param name="privateKeyHex">64 hex characters, optionally prefixed with 0x.</param>
    public PrivateKeySigner(string privateKeyHex)
    {
        if (string.IsNullOrWhiteSpace(privateKeyHex))
            throw new RemitError(ErrorCodes.InvalidPrivateKey,
                "Private key must not be empty.");

        var cleaned = privateKeyHex.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
            ? privateKeyHex[2..]
            : privateKeyHex;

        if (cleaned.Length != 64)
            throw new RemitError(ErrorCodes.InvalidPrivateKey,
                $"Invalid private key: expected 64 hex characters, got {cleaned.Length}. " +
                "Check that your REMITMD_KEY environment variable is set correctly.");

        try
        {
            _key = new EthECKey(cleaned);
        }
        catch (Exception)
        {
            throw new RemitError(ErrorCodes.InvalidPrivateKey,
                "Invalid private key: could not parse as secp256k1 key. " +
                "Ensure REMITMD_KEY is a valid Ethereum private key.", null, null);
        }
    }

    /// <inheritdoc />
    public string Address => _key.GetPublicAddress();

    /// <inheritdoc />
    public string Sign(byte[] hash)
    {
        var sig = _key.SignAndCalculateV(hash);
        var r = sig.R.PadLeft32();
        var s = sig.S.PadLeft32();
        var v = sig.V;

        // Build 65-byte signature: r (32) + s (32) + v (1)
        var result = new byte[65];
        Buffer.BlockCopy(r, 0, result, 0, 32);
        Buffer.BlockCopy(s, 0, result, 32, 32);
        result[64] = (byte)v[0];
        return "0x" + Convert.ToHexString(result).ToLowerInvariant();
    }
}

/// <summary>Byte array extensions for signature construction.</summary>
internal static class ByteArrayExtensions
{
    /// <summary>Pads a byte array to 32 bytes (left-padded with zeros).</summary>
    internal static byte[] PadLeft32(this byte[] src)
    {
        if (src.Length >= 32) return src;
        var padded = new byte[32];
        Buffer.BlockCopy(src, 0, padded, 32 - src.Length, src.Length);
        return padded;
    }
}

/// <summary>
/// Computes EIP-712 typed data hashes for remit.md API request authentication.
/// The domain separator binds signatures to a specific chain and contract.
/// </summary>
internal static class Eip712
{
    // EIP-712 domain type hash
    private static readonly byte[] DomainTypeHash = Keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // APIRequest type hash - must match server's auth.rs exactly
    private static readonly byte[] RequestTypeHash = Keccak256(
        "APIRequest(string method,string path,uint256 timestamp,bytes32 nonce)");

    /// <summary>
    /// Computes the EIP-712 hash for an APIRequest struct.
    ///
    /// Domain: name="remit.md", version="0.1", chainId, verifyingContract
    /// Struct: APIRequest(string method, string path, uint256 timestamp, bytes32 nonce)
    /// </summary>
    public static byte[] ComputeRequestDigest(
        long chainId,
        string verifyingContract,
        string method,
        string path,
        ulong timestamp,
        byte[] nonce)
    {
        var domainSeparator = BuildDomainSeparator(chainId, verifyingContract);
        var structHash = BuildStructHash(method, path, timestamp, nonce);

        // EIP-712 final hash: "\x19\x01" || domainSeparator || structHash
        var payload = new byte[66];
        payload[0] = 0x19;
        payload[1] = 0x01;
        Buffer.BlockCopy(domainSeparator, 0, payload, 2, 32);
        Buffer.BlockCopy(structHash, 0, payload, 34, 32);
        return Keccak256(payload);
    }

    private static byte[] BuildDomainSeparator(long chainId, string verifyingContract)
    {
        var nameHash    = Keccak256("remit.md");
        var versionHash = Keccak256("0.1");

        var encoded = AbiEncode(
            DomainTypeHash,
            nameHash,
            versionHash,
            PadUint256((ulong)chainId),
            PadAddress(verifyingContract)
        );
        return Keccak256(encoded);
    }

    private static byte[] BuildStructHash(string method, string path, ulong timestamp, byte[] nonce)
    {
        var methodHash = Keccak256(method);
        var pathHash   = Keccak256(path);

        // nonce is bytes32 - use directly (must be exactly 32 bytes)
        var paddedNonce = new byte[32];
        Buffer.BlockCopy(nonce, 0, paddedNonce, 0, Math.Min(nonce.Length, 32));

        var encoded = AbiEncode(
            RequestTypeHash,
            methodHash,
            pathHash,
            PadUint256(timestamp),
            paddedNonce
        );
        return Keccak256(encoded);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    internal static byte[] Keccak256(string text) => Keccak256(Encoding.UTF8.GetBytes(text));

    internal static byte[] Keccak256(byte[] data)
    {
        var keccak = new Sha3Keccack();
        return keccak.CalculateHash(data);
    }

    private static byte[] AbiEncode(params byte[][] parts)
    {
        var result = new byte[parts.Length * 32];
        for (var i = 0; i < parts.Length; i++)
            Buffer.BlockCopy(parts[i], 0, result, i * 32, Math.Min(parts[i].Length, 32));
        return result;
    }

    private static byte[] PadUint256(ulong value)
    {
        var result = new byte[32];
        var bytes = BitConverter.GetBytes(value);
        if (BitConverter.IsLittleEndian) Array.Reverse(bytes);
        Buffer.BlockCopy(bytes, 0, result, 32 - bytes.Length, bytes.Length);
        return result;
    }

    private static byte[] PadAddress(string address)
    {
        if (string.IsNullOrWhiteSpace(address)) return new byte[32];
        var result = new byte[32];
        var cleaned = address.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
            ? address[2..]
            : address;
        var addrBytes = HexToBytes(cleaned);
        Buffer.BlockCopy(addrBytes, 0, result, 32 - addrBytes.Length, addrBytes.Length);
        return result;
    }

    private static byte[] HexToBytes(string hex)
    {
        var result = new byte[hex.Length / 2];
        for (var i = 0; i < result.Length; i++)
            result[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
        return result;
    }
}
