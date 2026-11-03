using WFit.Api.Infrastructure;

namespace WFit.Api.Tests;

public class ApiKeyValidatorTests
{
    [Fact]
    public void Matching_key_is_valid() => Assert.True(ApiKeyValidator.IsValid("s3cret-key", "s3cret-key"));

    [Theory]
    [InlineData("wrong", "s3cret-key")]
    [InlineData("s3cret-ke", "s3cret-key")]
    [InlineData("S3CRET-KEY", "s3cret-key")]
    [InlineData("s3cret-key ", "s3cret-key")]
    public void Different_key_is_rejected(string provided, string expected) =>
        Assert.False(ApiKeyValidator.IsValid(provided, expected));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public void Missing_header_is_rejected(string? provided) => Assert.False(ApiKeyValidator.IsValid(provided, "s3cret-key"));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public void Unset_server_key_fails_closed(string? expected)
    {
        Assert.False(ApiKeyValidator.IsValid("anything", expected));
        Assert.False(ApiKeyValidator.IsValid("", expected));
        Assert.False(ApiKeyValidator.IsValid(null, expected));
    }
}
