using Dictator.App.Services;

namespace Dictator.App.UI;

internal sealed class RecordingOverlayForm : Form
{
    private readonly Label statusLabel;
    private readonly Label detailLabel;
    private readonly Button optionsButton;
    private readonly Button historyButton;
    private readonly ProgressBar activityProgressBar;
    private bool isBusy;

    public event EventHandler? SendRequested;
    public event EventHandler? CancelRequested;
    public event EventHandler? TogglePauseRequested;
    public event EventHandler? OptionsRequested;
    public event EventHandler? HistoryRequested;

    public RecordingOverlayForm()
    {
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(320, 112);
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

        activityProgressBar = new ProgressBar
        {
            Location = new Point(16, 68),
            Size = new Size(132, 14),
            Style = ProgressBarStyle.Marquee,
            MarqueeAnimationSpeed = 24,
            Visible = false
        };

        optionsButton = new Button
        {
            Text = "Options",
            Size = new Size(72, 26),
            Location = new Point(236, 74),
            TabStop = false
        };
        optionsButton.Click += (_, _) => OptionsRequested?.Invoke(this, EventArgs.Empty);

        historyButton = new Button
        {
            Text = "History",
            Size = new Size(72, 26),
            Location = new Point(158, 74),
            TabStop = false
        };
        historyButton.Click += (_, _) => HistoryRequested?.Invoke(this, EventArgs.Empty);

        Controls.Add(statusLabel);
        Controls.Add(detailLabel);
        Controls.Add(activityProgressBar);
        Controls.Add(historyButton);
        Controls.Add(optionsButton);

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
        if (isBusy)
        {
            return;
        }

        SetBusyVisuals(false);
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
        SetBusyVisuals(true);
        statusLabel.Text = message;
        detailLabel.Text = "Please wait...";
    }

    public void SetIdleError(string message)
    {
        SetBusyVisuals(false);
        statusLabel.Text = "Error";
        detailLabel.Text = message.Length > 64 ? message[..64] + "..." : message;
    }

    private void SetBusyVisuals(bool isBusy)
    {
        this.isBusy = isBusy;
        activityProgressBar.Visible = isBusy;
        optionsButton.Enabled = !isBusy;
        historyButton.Enabled = !isBusy;
    }

    private void PositionNearTopRight()
    {
        var bounds = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1024, 768);
        Location = new Point(bounds.Right - Width - 16, bounds.Top + 16);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Enter)
        {
            SendRequested?.Invoke(this, EventArgs.Empty);
            return true;
        }

        if (keyData == Keys.Escape)
        {
            CancelRequested?.Invoke(this, EventArgs.Empty);
            return true;
        }

        if (keyData == Keys.Space)
        {
            TogglePauseRequested?.Invoke(this, EventArgs.Empty);
            return true;
        }

        return base.ProcessCmdKey(ref msg, keyData);
    }
}
