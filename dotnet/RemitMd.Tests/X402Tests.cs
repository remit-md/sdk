using RemitMd;
using Xunit;

namespace RemitMd.Tests;

public sealed class X402Tests
{
    [Fact]
    public void AllowanceExceededError_ContainsAmounts()
    {
        var err = new AllowanceExceededError(1.5m, 0.1m);
        Assert.Equal(1.5m, err.AmountUsdc);
        Assert.Equal(0.1m, err.LimitUsdc);
    }

    [Fact]
    public void AllowanceExceededError_Message_ContainsBothAmounts()
    {
        var err = new AllowanceExceededError(1.5m, 0.1m);
        Assert.Contains("1.5", err.Message);
        Assert.Contains("0.1", err.Message);
    }

    [Fact]
    public void AllowanceExceededError_IsException()
    {
        var err = new AllowanceExceededError(1.0m, 0.5m);
        Assert.IsAssignableFrom<Exception>(err);
    }

    [Fact]
    public void PaymentRequired_HasDefaultValues()
    {
        var pr = new PaymentRequired();
        Assert.Equal("", pr.Scheme);
        Assert.Equal("0", pr.Amount);
        Assert.Equal("", pr.PayTo);
    }
}
