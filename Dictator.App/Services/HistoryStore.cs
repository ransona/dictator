using System.Text.Json;
using Dictator.App.Models;

namespace Dictator.App.Services;

internal sealed class HistoryStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string historyFilePath;

    public HistoryStore()
    {
        var appDataDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Dictator");
        Directory.CreateDirectory(appDataDirectory);
        historyFilePath = Path.Combine(appDataDirectory, "history.json");
    }

    public IReadOnlyList<HistoryMessage> Load()
    {
        if (!File.Exists(historyFilePath))
        {
            return [];
        }

        try
        {
            var json = File.ReadAllText(historyFilePath);
            var items = JsonSerializer.Deserialize<List<HistoryMessage>>(json, JsonOptions) ?? [];
            return items
                .OrderByDescending(x => x.CreatedAt)
                .ToList();
        }
        catch
        {
            return [];
        }
    }

    public void Add(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        var items = Load().ToList();
        items.Insert(0, new HistoryMessage
        {
            Text = text.Trim(),
            CreatedAt = DateTimeOffset.UtcNow
        });

        if (items.Count > 250)
        {
            items = items.Take(250).ToList();
        }

        Save(items);
    }

    public void Delete(string id)
    {
        var items = Load().Where(x => x.Id != id).ToList();
        Save(items);
    }

    public void Clear()
    {
        Save([]);
    }

    private void Save(IReadOnlyList<HistoryMessage> items)
    {
        var json = JsonSerializer.Serialize(items, JsonOptions);
        File.WriteAllText(historyFilePath, json);
    }
}
