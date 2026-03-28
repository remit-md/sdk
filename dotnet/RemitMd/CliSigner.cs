using System.Diagnostics;

namespace RemitMd;

/// <summary>
/// Signer backed by the <c>remit sign --digest</c> CLI command.
///
/// No key material lives in this process - signing is delegated to a subprocess
/// that holds the encrypted keystore at <c>~/.remit/keys/default.enc</c>.
/// The wallet address is cached at construction time via <c>remit address</c>.
///
/// <example>
/// <code>
/// var signer = CliSigner.Create();
/// var wallet = new Wallet(signer, chain: "base");
/// </code>
/// </example>
/// </summary>
public sealed class CliSigner : IRemitSigner
{
    private readonly string _cliPath;
    private readonly string _address;

    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    private CliSigner(string cliPath, string address)
    {
        _cliPath = cliPath;
        _address = address;
    }

    /// <summary>
    /// Creates a CliSigner by running <c>remit address</c> to fetch and cache
    /// the wallet address synchronously.
    /// </summary>
    /// <param name="cliPath">Path to the remit CLI binary. Defaults to "remit" (on PATH).</param>
    /// <exception cref="RemitError">
    /// Thrown when the CLI binary is not found, the keystore is missing,
    /// or the address output is malformed.
    /// </exception>
    public static CliSigner Create(string cliPath = "remit")
    {
        string stdout;
        try
        {
            stdout = RunCli(cliPath, "address", stdin: null);
        }
        catch (RemitError)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new RemitError(ErrorCodes.Unauthorized,
                $"CliSigner: failed to get address from CLI: {ex.Message}");
        }

        var address = stdout.Trim();
        if (!address.StartsWith("0x", StringComparison.OrdinalIgnoreCase) || address.Length != 42)
            throw new RemitError(ErrorCodes.Unauthorized,
                $"CliSigner: invalid address from CLI: {address}");

        return new CliSigner(cliPath, address);
    }

    /// <inheritdoc />
    public string Address => _address;

    /// <inheritdoc />
    public string Sign(byte[] hash)
    {
        var hexDigest = "0x" + Convert.ToHexString(hash).ToLowerInvariant();

        string stdout;
        try
        {
            stdout = RunCli(_cliPath, "sign --digest", stdin: hexDigest);
        }
        catch (RemitError)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new RemitError(ErrorCodes.ServerError,
                $"CliSigner: signing failed: {ex.Message}");
        }

        var sig = stdout.Trim();
        if (!sig.StartsWith("0x", StringComparison.OrdinalIgnoreCase) || sig.Length != 132)
            throw new RemitError(ErrorCodes.ServerError,
                $"CliSigner: invalid signature from CLI: {sig}");

        return sig;
    }

    /// <summary>
    /// Checks whether the CLI signer can be activated.
    /// <para>Detection order:</para>
    /// <list type="number">
    /// <item>CLI binary found on PATH (or at the given path).</item>
    /// <item><c>~/.remit/keys/default.meta</c> exists (keychain-backed, no password needed).</item>
    /// <item><c>~/.remit/keys/default.enc</c> exists AND <c>REMIT_KEY_PASSWORD</c> is set.</item>
    /// </list>
    /// </summary>
    public static bool IsAvailable(string cliPath = "remit")
    {
        // 1. Check CLI binary exists
        if (!CliExists(cliPath))
            return false;

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var keysDir = Path.Combine(home, ".remit", "keys");

        // 2. Keychain meta file (no password needed)
        if (File.Exists(Path.Combine(keysDir, "default.meta")))
            return true;

        // 3. Encrypted keystore + password
        if (File.Exists(Path.Combine(keysDir, "default.enc")))
        {
            var password = Environment.GetEnvironmentVariable("REMIT_KEY_PASSWORD");
            return !string.IsNullOrEmpty(password);
        }

        return false;
    }

    /// <inheritdoc />
    public override string ToString() => $"CliSigner {{ address: '{_address}' }}";

    // ─── Private helpers ────────────────────────────────────────────────────

    private static string RunCli(string cliPath, string args, string? stdin)
    {
        var psi = new ProcessStartInfo(cliPath, args)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        Process process;
        try
        {
            process = Process.Start(psi)
                ?? throw new RemitError(ErrorCodes.ServerError,
                    $"CliSigner: failed to start process: {cliPath}");
        }
        catch (System.ComponentModel.Win32Exception ex)
        {
            throw new RemitError(ErrorCodes.Unauthorized,
                $"CliSigner: CLI not found at '{cliPath}': {ex.Message}");
        }

        using (process)
        {
            if (stdin != null)
            {
                process.StandardInput.Write(stdin);
                process.StandardInput.Close();
            }
            else
            {
                process.StandardInput.Close();
            }

            if (!process.WaitForExit((int)Timeout.TotalMilliseconds))
            {
                try { process.Kill(); } catch { /* best effort */ }
                throw new RemitError(ErrorCodes.ServerError,
                    $"CliSigner: CLI timed out after {Timeout.TotalSeconds}s");
            }

            var stdout = process.StandardOutput.ReadToEnd();
            var stderr = process.StandardError.ReadToEnd();

            if (process.ExitCode != 0)
                throw new RemitError(ErrorCodes.ServerError,
                    $"CliSigner: CLI exited with code {process.ExitCode}: {stderr.Trim()}");

            return stdout;
        }
    }

    private static bool CliExists(string cliPath)
    {
        // If it's an absolute or relative path, check the file directly
        if (cliPath.Contains(Path.DirectorySeparatorChar) ||
            cliPath.Contains(Path.AltDirectorySeparatorChar))
            return File.Exists(cliPath);

        // Otherwise search PATH
        var pathEnv = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(pathEnv))
            return false;

        var separator = OperatingSystem.IsWindows() ? ';' : ':';
        var extensions = OperatingSystem.IsWindows()
            ? new[] { "", ".exe", ".cmd", ".bat" }
            : new[] { "" };

        foreach (var dir in pathEnv.Split(separator))
        {
            foreach (var ext in extensions)
            {
                var fullPath = Path.Combine(dir, cliPath + ext);
                if (File.Exists(fullPath))
                    return true;
            }
        }

        return false;
    }
}
