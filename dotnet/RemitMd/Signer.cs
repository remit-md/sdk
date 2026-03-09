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
/// Computes EIP-712 typed data hashes for remit.md payment messages.
/// The domain separator binds signatures to a specific chain and contract.
/// </summary>
internal static class Eip712
{
    // EIP-712 domain type hash
    private static readonly byte[] DomainTypeHash = Sha3(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // Payment type hash
    private static readonly byte[] PaymentTypeHash = Sha3(
        "Payment(address from,address to,uint256 amount,uint256 nonce,uint256 deadline,string memo)");

    /// <summary>Computes the domain separator for the given chain and contract.</summary>
    public static byte[] DomainSeparator(long chainId, string verifyingContract)
    {
        var name    = Sha3("remit.md");
        var version = Sha3("1");

        // abi.encode(DOMAIN_TYPE_HASH, name, version, chainId, verifyingContract)
        var encoded = AbiEncode(
            DomainTypeHash,
            name,
            version,
            PadUint256((ulong)chainId),
            PadAddress(verifyingContract)
        );
        return Sha3(encoded);
    }

    /// <summary>Computes the EIP-712 hash for a payment message.</summary>
    public static byte[] PaymentHash(
        byte[] domainSeparator,
        string from,
        string to,
        decimal amount,
        ulong nonce,
        ulong deadline,
        string memo)
    {
        var amountWei = ToWei(amount); // USDC uses 6 decimals
        var memoHash  = Sha3(memo);

        var structHash = Sha3(AbiEncode(
            PaymentTypeHash,
            PadAddress(from),
            PadAddress(to),
            PadUint256(amountWei),
            PadUint256(nonce),
            PadUint256(deadline),
            memoHash
        ));

        // EIP-712 final hash: \x19\x01 + domainSeparator + structHash
        var payload = new byte[2 + 32 + 32];
        payload[0] = 0x19;
        payload[1] = 0x01;
        Buffer.BlockCopy(domainSeparator, 0, payload, 2, 32);
        Buffer.BlockCopy(structHash, 0, payload, 34, 32);
        return Sha3(payload);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    private static byte[] Sha3(string text) => Sha3(Encoding.UTF8.GetBytes(text));

    private static byte[] Sha3(byte[] data)
    {
        var keccak = new Sha3Keccack();
        return keccak.CalculateHash(data);
    }

    private static byte[] AbiEncode(params byte[][] parts)
    {
        var result = new byte[parts.Length * 32];
        for (var i = 0; i < parts.Length; i++)
            Buffer.BlockCopy(parts[i], parts[i].Length > 32 ? 0 : 0, result, i * 32, Math.Min(parts[i].Length, 32));
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
        var result = new byte[32];
        var cleaned = address.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
            ? address[2..]
            : address;
        var addrBytes = HexToBytes(cleaned);
        Buffer.BlockCopy(addrBytes, 0, result, 32 - addrBytes.Length, addrBytes.Length);
        return result;
    }

    // USDC has 6 decimals; amount is in USDC units
    private static ulong ToWei(decimal amount) => (ulong)(amount * 1_000_000m);

    private static byte[] HexToBytes(string hex)
    {
        var result = new byte[hex.Length / 2];
        for (var i = 0; i < result.Length; i++)
            result[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
        return result;
    }
}
