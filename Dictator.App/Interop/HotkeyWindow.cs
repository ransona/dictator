using System.ComponentModel;

namespace Dictator.App.Interop;

internal sealed class HotkeyWindow : NativeWindow, IDisposable
{
    private const int HotkeyId = 0xD17A;
    private const int WmHotkey = 0x0312;
    private const uint ModWin = 0x0008;
    private const uint VkEscape = 0x1B;

    public event EventHandler? HotkeyPressed;

    public void Register()
    {
        CreateHandle(new CreateParams());
        if (!User32.RegisterHotKey(Handle, HotkeyId, ModWin, VkEscape))
        {
            throw new Win32Exception("Unable to register Win+Esc as a global hotkey.");
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WmHotkey && m.WParam == HotkeyId)
        {
            HotkeyPressed?.Invoke(this, EventArgs.Empty);
        }

        base.WndProc(ref m);
    }

    public void Dispose()
    {
        if (Handle != IntPtr.Zero)
        {
            User32.UnregisterHotKey(Handle, HotkeyId);
            DestroyHandle();
        }
    }
}
