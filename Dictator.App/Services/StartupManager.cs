using Microsoft.Win32;

namespace Dictator.App.Services;

internal sealed class StartupManager
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Dictator";

    public bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false);
        return key?.GetValue(ValueName)?.ToString() is not null;
    }

    public void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath);
        if (enabled)
        {
            key?.SetValue(ValueName, $"\"{Application.ExecutablePath}\"");
        }
        else
        {
            key?.DeleteValue(ValueName, false);
        }
    }
}
