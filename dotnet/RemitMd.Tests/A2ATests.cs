using RemitMd;
using Xunit;

namespace RemitMd.Tests;

public sealed class A2ATests
{
    [Fact]
    public void A2ATask_HasRequiredFields()
    {
        var task = new A2ATask
        {
            Id = "task-1",
            Status = new A2ATaskStatus { State = "working" },
        };
        Assert.Equal("task-1", task.Id);
        Assert.Equal("working", task.Status.State);
    }

    [Fact]
    public void A2AMessage_HasText()
    {
        var msg = new A2AMessage { Text = "hello" };
        Assert.Equal("hello", msg.Text);
    }

    [Fact]
    public void A2AClientOptions_HasEndpoint()
    {
        var opts = new A2AClientOptions
        {
            Endpoint = "https://example.com/a2a",
        };
        Assert.Equal("https://example.com/a2a", opts.Endpoint);
    }
}
