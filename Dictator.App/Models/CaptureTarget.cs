using System.Runtime.InteropServices;
using Dictator.App.Interop;

namespace Dictator.App.Models;

internal readonly record struct CaptureTarget(IntPtr WindowHandle, IntPtr FocusHandle)
{
    public static CaptureTarget Empty => new(IntPtr.Zero, IntPtr.Zero);

    public static CaptureTarget CaptureActive()
    {
        var foreground = User32.GetForegroundWindow();
        if (foreground == IntPtr.Zero)
        {
            return Empty;
        }

        var threadId = User32.GetWindowThreadProcessId(foreground, out _);
        var info = new User32.GuiThreadInfo
        {
            cbSize = (uint)Marshal.SizeOf<User32.GuiThreadInfo>()
        };

        if (!User32.GetGUIThreadInfo(threadId, ref info))
        {
            return new CaptureTarget(foreground, foreground);
        }

        return new CaptureTarget(
            info.hwndActive != IntPtr.Zero ? info.hwndActive : foreground,
            info.hwndFocus != IntPtr.Zero ? info.hwndFocus : foreground);
    }

    public async Task RestoreAndPasteAsync(string text)
    {
        if (WindowHandle == IntPtr.Zero)
        {
            return;
        }

        Clipboard.SetText(text);

        if (User32.IsIconic(WindowHandle))
        {
            User32.ShowWindow(WindowHandle, User32.SwRestore);
        }

        User32.SetForegroundWindow(WindowHandle);
        User32.BringWindowToTop(WindowHandle);

        await Task.Delay(120);
        RestoreFocus();
        await Task.Delay(80);
        SendPasteShortcut();
    }

    private void RestoreFocus()
    {
        if (FocusHandle == IntPtr.Zero)
        {
            return;
        }

        var currentThread = User32.GetWindowThreadProcessId(User32.GetForegroundWindow(), IntPtr.Zero);
        var targetThread = User32.GetWindowThreadProcessId(FocusHandle, IntPtr.Zero);

        User32.AttachThreadInput(currentThread, targetThread, true);
        try
        {
            User32.SetFocus(FocusHandle);
        }
        finally
        {
            User32.AttachThreadInput(currentThread, targetThread, false);
        }
    }

    private static void SendPasteShortcut()
    {
        var inputs = new[]
        {
            CreateKey(User32.VkControl, 0),
            CreateKey(User32.VkV, 0),
            CreateKey(User32.VkV, User32.KeyeventfKeyup),
            CreateKey(User32.VkControl, User32.KeyeventfKeyup)
        };

        User32.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<User32.Input>());
    }

    private static User32.Input CreateKey(ushort key, uint flags)
    {
        return new User32.Input
        {
            type = User32.InputKeyboard,
            U = new User32.InputUnion
            {
                ki = new User32.KeyboardInput
                {
                    wVk = key,
                    dwFlags = flags
                }
            }
        };
    }
}
