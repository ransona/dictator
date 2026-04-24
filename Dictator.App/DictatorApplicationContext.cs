using Dictator.App.Interop;
using Dictator.App.Models;
using Dictator.App.Services;
using Dictator.App.UI;

namespace Dictator.App;

internal sealed class DictatorApplicationContext : ApplicationContext
{
    private readonly RegistrySettingsStore settingsStore = new();
    private readonly StartupManager startupManager = new();
    private readonly OpenAiTranscriptionService transcriptionService = new();
    private readonly AudioRecorder audioRecorder = new();
    private readonly HotkeyWindow hotkeyWindow = new();
    private readonly NotifyIcon notifyIcon;
    private readonly RecordingOverlayForm overlay;
    private readonly System.Windows.Forms.Timer overlayTimer;

    private AppSettings settings;
    private CaptureTarget captureTarget = CaptureTarget.Empty;
    private bool isSending;

    public DictatorApplicationContext()
    {
        settings = settingsStore.Load();

        overlay = new RecordingOverlayForm();
        overlay.SendRequested += async (_, _) => await SendRecordingAsync();
        overlay.CancelRequested += async (_, _) => await CancelRecordingAsync();
        overlay.TogglePauseRequested += (_, _) => TogglePause();
        overlay.OptionsRequested += (_, _) => ShowOptions();

        overlayTimer = new System.Windows.Forms.Timer { Interval = 200 };
        overlayTimer.Tick += (_, _) => overlay.UpdateState(audioRecorder.State, audioRecorder.RecordedDuration);
        overlayTimer.Start();

        notifyIcon = new NotifyIcon
        {
            Icon = SystemIcons.Information,
            Visible = true,
            Text = "Dictator",
            ContextMenuStrip = BuildTrayMenu()
        };
        notifyIcon.DoubleClick += (_, _) => BeginRecording();

        hotkeyWindow.HotkeyPressed += (_, _) => BeginRecording();
        try
        {
            hotkeyWindow.Register();
        }
        catch (Exception ex)
        {
            ShowBalloon("Hotkey unavailable", ex.Message);
        }

        if (string.IsNullOrWhiteSpace(settings.ApiKey))
        {
            ShowBalloon("OpenAI API key required", "Open Options from the tray menu to enter your API key.");
        }
    }

    private ContextMenuStrip BuildTrayMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Start Dictation", null, (_, _) => BeginRecording());
        menu.Items.Add("Options", null, (_, _) => ShowOptions());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => ExitThread());
        return menu;
    }

    private void BeginRecording()
    {
        if (isSending)
        {
            return;
        }

        if (string.IsNullOrWhiteSpace(settings.ApiKey))
        {
            ShowOptions();
            return;
        }

        if (audioRecorder.State != RecordingState.Idle)
        {
            return;
        }

        captureTarget = CaptureTarget.CaptureActive();
        audioRecorder.Start();
        overlay.ShowForState(audioRecorder.State);
    }

    private void TogglePause()
    {
        if (audioRecorder.State == RecordingState.Recording)
        {
            audioRecorder.Pause();
        }
        else if (audioRecorder.State == RecordingState.Paused)
        {
            audioRecorder.Resume();
        }

        overlay.UpdateState(audioRecorder.State, audioRecorder.RecordedDuration);
    }

    private async Task CancelRecordingAsync()
    {
        if (audioRecorder.State == RecordingState.Idle)
        {
            overlay.Hide();
            return;
        }

        await audioRecorder.StopAsync(cancel: true);
        overlay.Hide();
    }

    private async Task SendRecordingAsync()
    {
        if (audioRecorder.State == RecordingState.Idle || isSending)
        {
            return;
        }

        isSending = true;
        overlay.SetBusy("Transcribing...");

        try
        {
            var audio = await audioRecorder.StopAsync(cancel: false);
            if (audio is null || audio.Length == 0)
            {
                overlay.Hide();
                return;
            }

            var transcript = await transcriptionService.TranscribeAsync(
                audio,
                settings.ApiKey,
                settings.Model,
                CancellationToken.None);
            overlay.Hide();

            if (!string.IsNullOrWhiteSpace(transcript))
            {
                await captureTarget.RestoreAndPasteAsync(transcript);
            }
        }
        catch (Exception ex)
        {
            overlay.SetIdleError(ex.Message);
            ShowBalloon("Dictation failed", ex.Message);
        }
        finally
        {
            isSending = false;
        }
    }

    private void ShowOptions()
    {
        var shouldResume = audioRecorder.State == RecordingState.Recording;
        if (shouldResume)
        {
            audioRecorder.Pause();
            overlay.UpdateState(audioRecorder.State, audioRecorder.RecordedDuration);
        }

        using var form = new OptionsForm(settings, startupManager.IsEnabled());
        if (form.ShowDialog() == DialogResult.OK)
        {
            settings = form.Settings;
            settingsStore.Save(settings);
            startupManager.SetEnabled(form.StartOnLogin);
        }

        if (shouldResume && audioRecorder.State == RecordingState.Paused && !isSending)
        {
            audioRecorder.Resume();
            overlay.UpdateState(audioRecorder.State, audioRecorder.RecordedDuration);
        }
    }

    private void ShowBalloon(string title, string message)
    {
        notifyIcon.BalloonTipTitle = title;
        notifyIcon.BalloonTipText = message;
        notifyIcon.ShowBalloonTip(4000);
    }

    protected override void ExitThreadCore()
    {
        hotkeyWindow.Dispose();
        overlayTimer.Stop();
        overlayTimer.Dispose();
        overlay.Dispose();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        audioRecorder.Dispose();
        base.ExitThreadCore();
    }
}
