namespace Dictator.App.Models;

internal sealed class AppSettings
{
    public string ApiKey { get; init; } = string.Empty;

    public string TranscriptionModel { get; init; } = "whisper-1";

    public string EmailRewriteModel { get; init; } = "gpt-4o-mini";
}
