using Dictator.App.Services;

namespace Dictator.App.UI;

internal sealed class RecordingOverlayForm : Form
{
    private readonly Label statusLabel;
    private readonly Label detailLabel;
    private readonly Button optionsButton;

    public event EventHandler? SendRequested;
    public event EventHandler? CancelRequested;
    public event EventHandler? TogglePauseRequested;
    public event EventHandler? OptionsRequested;

    public RecordingOverlayForm()
    {
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(240, 112);
        BackColor = Color.WhiteSmoke;
        ControlBox = false;
        KeyPreview = true;
        Text = "Dictator";

        statusLabel = new Label
        {
            AutoSize = true,
            Font = new Font("Segoe UI", 11F, FontStyle.Bold, GraphicsUnit.Point),
            Location = new Point(14, 14),
            Text = "Recording"
        };

        detailLabel = new Label
        {
            AutoSize = true,
            Location = new Point(16, 44),
            Text = "Enter send  |  Space pause  |  Esc cancel"
        };

        optionsButton = new Button
        {
            Text = "Options",
            Size = new Size(72, 26),
            Location = new Point(152, 74)
        };
        optionsButton.Click += (_, _) => OptionsRequested?.Invoke(this, EventArgs.Empty);

        Controls.Add(statusLabel);
        Controls.Add(detailLabel);
        Controls.Add(optionsButton);

        KeyDown += OnKeyDown;
    }

    public void ShowForState(RecordingState state)
    {
        PositionNearTopRight();
        UpdateState(state, TimeSpan.Zero);
        Show();
        Activate();
    }

    public void UpdateState(RecordingState state, TimeSpan elapsed)
    {
        statusLabel.Text = state switch
        {
            RecordingState.Recording => $"Recording {elapsed:mm\\:ss}",
            RecordingState.Paused => $"Paused {elapsed:mm\\:ss}",
            _ => "Ready"
        };

        detailLabel.Text = state switch
        {
            RecordingState.Recording => "Enter send  |  Space pause  |  Esc cancel",
            RecordingState.Paused => "Enter send  |  Space resume  |  Esc cancel",
            _ => "Win+Esc starts dictation"
        };
    }

    public void SetBusy(string message)
    {
        statusLabel.Text = message;
        detailLabel.Text = "Please wait...";
    }

    public void SetIdleError(string message)
    {
        statusLabel.Text = "Error";
        detailLabel.Text = message.Length > 64 ? message[..64] + "..." : message;
    }

    private void PositionNearTopRight()
    {
        var bounds = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1024, 768);
        Location = new Point(bounds.Right - Width - 16, bounds.Top + 16);
    }

    private void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Enter)
        {
            e.Handled = true;
            e.SuppressKeyPress = true;
            SendRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        if (e.KeyCode == Keys.Escape)
        {
            e.Handled = true;
            e.SuppressKeyPress = true;
            CancelRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        if (e.KeyCode == Keys.Space)
        {
            e.Handled = true;
            e.SuppressKeyPress = true;
            TogglePauseRequested?.Invoke(this, EventArgs.Empty);
        }
    }
}
