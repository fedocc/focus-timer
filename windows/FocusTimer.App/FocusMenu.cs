using FocusTimer.Core;

namespace FocusTimer.Windows;

public sealed class FocusMenu : Form
{
    private readonly FocusController controller;
    private readonly TextBox search = new() { PlaceholderText = "Поиск по приложениям", Dock = DockStyle.Fill, AccessibleName = "Поиск по приложениям" };
    private readonly CheckedListBox apps = new() { Dock = DockStyle.Fill, CheckOnClick = true, IntegralHeight = false, AccessibleName = "Разрешенные приложения" };
    private readonly ListBox activeApps = new() { Dock = DockStyle.Fill, IntegralHeight = false, AccessibleName = "Открыть разрешенное приложение" };
    private readonly NumericUpDown minutes = new() { Minimum = 1, Maximum = 720, Width = 75, AccessibleName = "Длительность в минутах" };
    private readonly Label heading = new() { Text = "Фокус", AutoSize = true, Font = new Font("Segoe UI", 16, FontStyle.Bold) };
    private readonly Label description = new() { Text = "Выберите приложения для работы", AutoSize = true };
    private readonly Label countdown = new() { Dock = DockStyle.Top, Height = 75, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Segoe UI", 34) };
    private readonly Button start = new() { Text = "Начать", Dock = DockStyle.Fill, Height = 38 };
    private readonly Button refresh = new() { Text = "Обновить", AutoSize = true };
    private readonly FlowLayoutPanel duration = new() { Dock = DockStyle.Fill, AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = Padding.Empty };
    private readonly Button quit = new() { Text = "Выйти", AutoSize = true };
    private LiveApp[] allApps = [];
    private LiveApp[] visibleApps = [];
    private bool rendering;
    private bool allowClose;
    public event Action? StartRequested;
    public event Action? QuitRequested;
    public event Action<AppBookmark>? OpenRequested;
    public FocusMenu(FocusController controller)
    {
        this.controller = controller;
        Text = "Фокус Таймер"; Font = new Font("Segoe UI", 10); ClientSize = new Size(380, 520);
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
        ShowInTaskbar = false; TopMost = true; AutoScaleMode = AutoScaleMode.Dpi; AutoScaleDimensions = new SizeF(96, 96);
        BackColor = SystemColors.Window; ForeColor = SystemColors.WindowText;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 9, Padding = new Padding(16) };
        foreach (var height in new[] { 38, 30, 40, 250, 38, 42, 36, 0, 0 }) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        layout.Controls.Add(heading, 0, 0); layout.Controls.Add(description, 0, 1);
        var searchRow = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
        searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        searchRow.Controls.Add(search, 0, 0); searchRow.Controls.Add(refresh, 1, 0); layout.Controls.Add(searchRow, 0, 2);
        var list = new Panel { Dock = DockStyle.Fill }; list.Controls.Add(apps); list.Controls.Add(activeApps); list.Controls.Add(countdown);
        layout.Controls.Add(list, 0, 3);
        duration.Controls.Add(new Label { Text = "Время", AutoSize = true, Padding = new Padding(0, 5, 12, 0) });
        duration.Controls.Add(minutes); duration.Controls.Add(new Label { Text = "мин", AutoSize = true, Padding = new Padding(4, 5, 0, 0) });
        layout.Controls.Add(duration, 0, 4); layout.Controls.Add(start, 0, 5);
        var footer = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, Margin = Padding.Empty };
        footer.Controls.Add(new Label { Text = "До конца таймера без отмены", AutoSize = true, Padding = new Padding(0, 5, 6, 0), Font = new Font("Segoe UI", 8) });
        footer.Controls.Add(quit); layout.Controls.Add(footer, 0, 6); Controls.Add(layout);
        search.TextChanged += (_, _) => RenderList(); refresh.Click += (_, _) => RefreshApps();
        apps.ItemCheck += (_, e) => {
            if (rendering || controller.Session is not null) return;
            try { controller.Select(visibleApps[e.Index].Bookmark, e.NewValue == CheckState.Checked); }
            catch (Exception error) { e.NewValue = e.CurrentValue; ShowError(error); }
            BeginInvoke(() => start.Enabled = controller.Selection.Length > 0);
        };
        minutes.ValueChanged += (_, _) => { if (!rendering) Execute(() => controller.SetMinutes((int)minutes.Value)); };
        start.Click += (_, _) => StartRequested?.Invoke(); quit.Click += (_, _) => QuitRequested?.Invoke();
        activeApps.DoubleClick += (_, _) => OpenActive();
        activeApps.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { OpenActive(); e.Handled = true; } };
        FormClosing += (_, e) => { if (!allowClose) { e.Cancel = true; Hide(); } };
        RefreshApps(); RenderState();
    }
    public void ShowError(Exception error) => MessageBox.Show(this, error.Message, "Фокус", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    private void Execute(Action action) { try { action(); } catch (Exception error) { ShowError(error); } }
    private void OpenActive() { if (activeApps.SelectedIndex >= 0) OpenRequested?.Invoke(controller.Session!.Applications[activeApps.SelectedIndex]); }
    public void RefreshApps()
    {
        allApps = DesktopService.Snapshot(controller.Session?.Applications ?? controller.Selection); RenderList();
    }
    private void RenderList()
    {
        if (controller.Session is not null) return;
        var terms = search.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        visibleApps = allApps.Where(a => terms.All(t => a.Bookmark.Name.Contains(t, StringComparison.CurrentCultureIgnoreCase))).ToArray();
        rendering = true; apps.BeginUpdate(); apps.Items.Clear();
        foreach (var app in visibleApps) apps.Items.Add(app.Bookmark.Name + (app.Windows.Length == 0 ? " · не запущено" : " · все окна"), ApplicationPolicy.Allows(controller.Selection, app.Bookmark));
        apps.EndUpdate(); rendering = false;
    }
    public void RenderState()
    {
        rendering = true;
        var active = controller.Session is not null;
        search.Enabled = refresh.Enabled = !active; apps.Visible = !active; activeApps.Visible = countdown.Visible = active;
        duration.Visible = start.Visible = quit.Visible = !active;
        description.Text = active ? "Разрешенные приложения · двойной щелчок, чтобы открыть" : "Выберите приложения для работы";
        description.Font = new Font("Segoe UI", active ? 8 : 10);
        minutes.Value = controller.Minutes; start.Enabled = controller.Selection.Length > 0;
        if (active)
        {
            activeApps.Items.Clear(); foreach (var item in controller.Session!.Applications) activeApps.Items.Add(item.Name + " · все окна");
        }
        rendering = false;
        UpdateCountdown();
    }
    public void UpdateCountdown() => countdown.Text = ApplicationPolicy.Countdown(controller.RemainingMs);
    public void ShowNearTray()
    {
        RefreshApps(); RenderState();
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(Math.Max(area.Left, area.Right - Width - 12), Math.Max(area.Top, area.Bottom - Height - 12));
        Show(); Activate();
    }
    public void CloseForExit() { allowClose = true; Close(); }
    public void SetSearchForTest(string query) => search.Text = query;
    public int VisibleAppCount => apps.Items.Count;
}
