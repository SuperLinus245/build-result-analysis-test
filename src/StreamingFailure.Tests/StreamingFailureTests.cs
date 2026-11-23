using NUnit.Framework;

namespace StreamingFailureTests;

public class StreamingFailureTests
{
    [Test]
    public void StreamingUnmatchedAgentFailure()
    {
        Assert.Fail("Streaming fixture: unmatched agent failure");
    }
}
