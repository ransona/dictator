using Dictator.App.Models;

namespace Dictator.App.UI;

internal sealed class HistoryForm : Form
{
    private readonly ListBox historyListBox;
    private readonly TextBox messageTextBox;
    private readonly Button useSelectedButton;
    private readonly Button deleteSelectedButton;
    private readonly Button clearAllButton;
    private readonly Button closeButton;

    public event Action<HistoryMessage>? UseRequested;
    public event Action<HistoryMessage>? DeleteRequested;
    public event EventHandler? ClearAllRequested;

    public HistoryForm(IReadOnlyList<HistoryMessage> items)
    {
        Text = "Dictator History";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(860, 460);
        MinimumSize = new Size(760, 420);

        historyListBox = new ListBox
        {
            Location = new Point(12, 12),
            Size = new Size(300, 396),
            Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left
        };
        historyListBox.SelectedIndexChanged += (_, _) => UpdatePreview();
        historyListBox.DoubleClick += (_, _) => UseCurrentSelection();

        messageTextBox = new TextBox
        {
            Location = new Point(324, 12),
            Size = new Size(524, 396),
            Multiline = true,
            ScrollBars = ScrollBars.Vertical,
            ReadOnly = true,
            Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right
        };

        useSelectedButton = new Button
        {
            Text = "Use Selected",
            Location = new Point(324, 420),
            Size = new Size(110, 28),
            Anchor = AnchorStyles.Bottom | AnchorStyles.Left
        };
        useSelectedButton.Click += (_, _) => UseCurrentSelection();

        deleteSelectedButton = new Button
        {
            Text = "Delete Selected",
            Location = new Point(440, 420),
            Size = new Size(110, 28),
            Anchor = AnchorStyles.Bottom | AnchorStyles.Left
        };
        deleteSelectedButton.Click += (_, _) =>
        {
            if (historyListBox.SelectedItem is HistoryMessage item)
            {
                DeleteRequested?.Invoke(item);
                LoadItems(historyListBox.Items.Cast<HistoryMessage>().Where(x => x.Id != item.Id).ToList());
            }
        };

        clearAllButton = new Button
        {
            Text = "Clear All",
            Location = new Point(556, 420),
            Size = new Size(90, 28),
            Anchor = AnchorStyles.Bottom | AnchorStyles.Left
        };
        clearAllButton.Click += (_, _) =>
        {
            if (MessageBox.Show(
                    this,
                    "Delete all saved messages?",
                    "Clear history",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning) == DialogResult.Yes)
            {
                ClearAllRequested?.Invoke(this, EventArgs.Empty);
                LoadItems([]);
            }
        };

        closeButton = new Button
        {
            Text = "Close",
            Location = new Point(758, 420),
            Size = new Size(90, 28),
            Anchor = AnchorStyles.Bottom | AnchorStyles.Right,
            DialogResult = DialogResult.Cancel
        };

        CancelButton = closeButton;

        Controls.AddRange(
        [
            historyListBox,
            messageTextBox,
            useSelectedButton,
            deleteSelectedButton,
            clearAllButton,
            closeButton
        ]);

        LoadItems(items);
    }

    private void LoadItems(IReadOnlyList<HistoryMessage> items)
    {
        historyListBox.BeginUpdate();
        historyListBox.Items.Clear();
        foreach (var item in items.OrderByDescending(x => x.CreatedAt))
        {
            historyListBox.Items.Add(item);
        }
        historyListBox.EndUpdate();

        if (historyListBox.Items.Count > 0)
        {
            historyListBox.SelectedIndex = 0;
        }
        else
        {
            messageTextBox.Text = string.Empty;
        }

        UpdateButtons();
    }

    private void UpdatePreview()
    {
        messageTextBox.Text = historyListBox.SelectedItem is HistoryMessage item ? item.Text : string.Empty;
        UpdateButtons();
    }

    private void UpdateButtons()
    {
        var hasSelection = historyListBox.SelectedItem is HistoryMessage;
        useSelectedButton.Enabled = hasSelection;
        deleteSelectedButton.Enabled = hasSelection;
        clearAllButton.Enabled = historyListBox.Items.Count > 0;
    }

    private void UseCurrentSelection()
    {
        if (historyListBox.SelectedItem is not HistoryMessage item)
        {
            return;
        }

        UseRequested?.Invoke(item);
        DialogResult = DialogResult.OK;
        Close();
    }
}
