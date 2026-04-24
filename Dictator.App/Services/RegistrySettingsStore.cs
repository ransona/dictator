using Microsoft.Win32;
using Dictator.App.Models;

namespace Dictator.App.Services;

internal sealed class RegistrySettingsStore
{
    private const string RootPath = @"Software\Dictator";
    private const string ApiKeyName = "ApiKey";

    public AppSettings Load()
    {
        using var key = Registry.CurrentUser.CreateSubKey(RootPath);
        return new AppSettings
        {
            ApiKey = key?.GetValue(ApiKeyName, string.Empty)?.ToString() ?? string.Empty
        };
    }

    public void Save(AppSettings settings)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RootPath);
        key?.SetValue(ApiKeyName, settings.ApiKey);
    }
}
