using Dictator.App.Models;

namespace Dictator.App.UI;

internal sealed class OptionsForm : Form
{
    private readonly TextBox apiKeyTextBox;
    private readonly CheckBox startOnLoginCheckBox;

    public OptionsForm(AppSettings settings, bool startOnLogin)
    {
        Text = "Dictator Options";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterScreen;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        ClientSize = new Size(420, 170);

        var apiKeyLabel = new Label
        {
            AutoSize = true,
            Location = new Point(16, 18),
            Text = "OpenAI API key"
        };

        apiKeyTextBox = new TextBox
        {
            Location = new Point(16, 42),
            Size = new Size(388, 23),
            UseSystemPasswordChar = true,
            Text = settings.ApiKey
        };

        var hintLabel = new Label
        {
            AutoSize = true,
            Location = new Point(16, 74),
            Text = "Dictator stores this key under HKCU\\Software\\Dictator."
        };

        startOnLoginCheckBox = new CheckBox
        {
            AutoSize = true,
            Location = new Point(16, 102),
            Text = "Start Dictator when I sign in",
            Checked = startOnLogin
        };

        var saveButton = new Button
        {
            Text = "Save",
            DialogResult = DialogResult.OK,
            Location = new Point(248, 132),
            Size = new Size(75, 27)
        };

        var cancelButton = new Button
        {
            Text = "Cancel",
            DialogResult = DialogResult.Cancel,
            Location = new Point(329, 132),
            Size = new Size(75, 27)
        };

        AcceptButton = saveButton;
        CancelButton = cancelButton;

        Controls.AddRange(
        [
            apiKeyLabel,
            apiKeyTextBox,
            hintLabel,
            startOnLoginCheckBox,
            saveButton,
            cancelButton
        ]);
    }

    public AppSettings Settings => new()
    {
        ApiKey = apiKeyTextBox.Text.Trim()
    };

    public bool StartOnLogin => startOnLoginCheckBox.Checked;
}
