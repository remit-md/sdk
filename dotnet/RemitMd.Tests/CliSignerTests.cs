using RemitMd;
using Xunit;

namespace RemitMd.Tests;

/// <summary>
/// Unit tests for the <see cref="CliSigner"/> class.
/// These tests verify error handling and availability checks without
/// requiring the actual remit CLI binary to be installed.
/// </summary>
public sealed class CliSignerTests
{
    // ─── IsAvailable ─────────────────────────────────────────────────────────

    [Fact]
    public void IsAvailable_NonExistentBinary_ReturnsFalse()
    {
        Assert.False(CliSigner.IsAvailable("nonexistent-binary-that-does-not-exist-xyz"));
    }

    [Fact]
    public void IsAvailable_NoPassword_ReturnsFalse()
    {
        // Temporarily unset REMIT_SIGNER_KEY and REMIT_KEY_PASSWORD
        var oldNew = Environment.GetEnvironmentVariable("REMIT_SIGNER_KEY");
        var oldLegacy = Environment.GetEnvironmentVariable("REMIT_KEY_PASSWORD");
        try
        {
            Environment.SetEnvironmentVariable("REMIT_SIGNER_KEY", null);
            Environment.SetEnvironmentVariable("REMIT_KEY_PASSWORD", null);
            Assert.False(CliSigner.IsAvailable());
        }
        finally
        {
            Environment.SetEnvironmentVariable("REMIT_SIGNER_KEY", oldNew);
            Environment.SetEnvironmentVariable("REMIT_KEY_PASSWORD", oldLegacy);
        }
    }

    [Fact]
    public void IsAvailable_NoKeystore_ReturnsFalse()
    {
        // Even if password is set, without keystore it should be false
        // (unless the test env happens to have one — we just check it doesn't throw)
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var keystore = Path.Combine(home, ".remit", "keys", "default.enc");

        if (!File.Exists(keystore))
        {
            var oldNew = Environment.GetEnvironmentVariable("REMIT_SIGNER_KEY");
            var oldLegacy = Environment.GetEnvironmentVariable("REMIT_KEY_PASSWORD");
            try
            {
                Environment.SetEnvironmentVariable("REMIT_SIGNER_KEY", "test-password");
                Environment.SetEnvironmentVariable("REMIT_KEY_PASSWORD", null);
                Assert.False(CliSigner.IsAvailable());
            }
            finally
            {
                Environment.SetEnvironmentVariable("REMIT_SIGNER_KEY", oldNew);
                Environment.SetEnvironmentVariable("REMIT_KEY_PASSWORD", oldLegacy);
            }
        }
        // If keystore exists in test env, this test is a no-op (acceptable)
    }

    // ─── Create ──────────────────────────────────────────────────────────────

    [Fact]
    public void Create_NonExistentBinary_ThrowsRemitError()
    {
        var ex = Assert.Throws<RemitError>(() =>
            CliSigner.Create("nonexistent-binary-that-does-not-exist-xyz"));

        Assert.Equal(ErrorCodes.Unauthorized, ex.Code);
        Assert.Contains("CliSigner", ex.Message);
    }

    [Fact]
    public void Create_DefaultPath_ThrowsWhenCliNotInstalled()
    {
        // In CI environments the remit CLI is typically not installed,
        // so this verifies the error path. If it IS installed, the test
        // still passes (Create succeeds or throws a meaningful error).
        try
        {
            var signer = CliSigner.Create();
            // If we get here, the CLI is installed — just verify the address looks valid
            Assert.StartsWith("0x", signer.Address);
            Assert.Equal(42, signer.Address.Length);
        }
        catch (RemitError ex)
        {
            // Expected in most test environments
            Assert.True(
                ex.Code == ErrorCodes.Unauthorized || ex.Code == ErrorCodes.ServerError,
                $"Unexpected error code: {ex.Code}");
        }
    }

    // ─── ToString ────────────────────────────────────────────────────────────

    [Fact]
    public void IsAvailable_AllConditions_WithoutKeystore()
    {
        // Verify that IsAvailable checks all three conditions:
        // 1. binary exists, 2. keystore exists, 3. password set
        // Without keystore, should always be false regardless of password
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var keystore = Path.Combine(home, ".remit", "keys", "default.enc");

        if (File.Exists(keystore))
        {
            // Can't test "no keystore" scenario — skip
            return;
        }

        var oldNew = Environment.GetEnvironmentVariable("REMIT_SIGNER_KEY");
        var oldLegacy = Environment.GetEnvironmentVariable("REMIT_KEY_PASSWORD");
        try
        {
            Environment.SetEnvironmentVariable("REMIT_SIGNER_KEY", "some-password");
            Environment.SetEnvironmentVariable("REMIT_KEY_PASSWORD", null);
            // Even with password set, no keystore = not available
            Assert.False(CliSigner.IsAvailable());
        }
        finally
        {
            Environment.SetEnvironmentVariable("REMIT_SIGNER_KEY", oldNew);
            Environment.SetEnvironmentVariable("REMIT_KEY_PASSWORD", oldLegacy);
        }
    }
}
