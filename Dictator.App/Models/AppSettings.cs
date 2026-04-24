namespace Dictator.App.Models;

internal sealed class AppSettings
{
    public string ApiKey { get; init; } = string.Empty;

    public string Model { get; init; } = "whisper-1";
}
