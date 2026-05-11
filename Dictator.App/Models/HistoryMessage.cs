namespace Dictator.App.Models;

internal sealed class HistoryMessage
{
    public string Id { get; init; } = Guid.NewGuid().ToString("N");

    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;

    public string Text { get; init; } = string.Empty;

    public override string ToString()
    {
        var preview = Text.ReplaceLineEndings(" ").Trim();
        if (preview.Length > 48)
        {
            preview = preview[..48] + "...";
        }

        return $"{CreatedAt.LocalDateTime:yyyy-MM-dd HH:mm:ss}  {preview}";
    }
}
