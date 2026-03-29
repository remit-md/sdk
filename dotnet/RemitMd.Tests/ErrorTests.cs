using RemitMd;
using Xunit;

namespace RemitMd.Tests;

public sealed class ErrorTests
{
    [Fact]
    public void RemitError_HasCode_And_Message()
    {
        var err = new RemitError("TEST_CODE", "test message");
        Assert.Equal("TEST_CODE", err.Code);
        Assert.Equal("test message", err.Message);
    }

    [Fact]
    public void RemitError_ToString_IncludesCode()
    {
        var err = new RemitError("INVALID_ADDRESS", "bad addr");
        Assert.Contains("INVALID_ADDRESS", err.ToString());
    }

    [Fact]
    public void ErrorCodes_AreStableStrings()
    {
        Assert.Equal("INVALID_SIGNATURE", ErrorCodes.InvalidSignature);
        Assert.Equal("INSUFFICIENT_BALANCE", ErrorCodes.InsufficientBalance);
        Assert.Equal("ESCROW_EXPIRED", ErrorCodes.EscrowExpired);
        Assert.Equal("TAB_DEPLETED", ErrorCodes.TabDepleted);
        Assert.Equal("TAB_EXPIRED", ErrorCodes.TabExpired);
        Assert.Equal("BOUNTY_EXPIRED", ErrorCodes.BountyExpired);
        Assert.Equal("NETWORK_ERROR", ErrorCodes.NetworkError);
    }

    [Fact]
    public void RemitError_WithContext_StoresValues()
    {
        var ctx = new Dictionary<string, object> { ["amount"] = "5.00" };
        var err = new RemitError("TEST", "msg", ctx);
        Assert.NotNull(err.Context);
    }

    [Fact]
    public void ErrorCodes_TabLimitExceeded_IsAliasForTabDepleted()
    {
        Assert.Equal(ErrorCodes.TabDepleted, ErrorCodes.TabLimitExceeded);
    }
}
