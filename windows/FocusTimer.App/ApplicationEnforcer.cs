using FocusTimer.Core;

namespace FocusTimer.Windows;

public sealed class ShieldForm : Form
{
    private readonly Label countdown = new() { Dock = DockStyle.Top, Height = 80, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Segoe UI", 38) };
    private readonly FlowLayoutPanel buttons = new() { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Anchor = AnchorStyles.None };
    protected override bool ShowWithoutActivation => true;
    public ShieldForm(Rectangle bounds, IEnumerable<AppBookmark> allowed, Action<AppBookmark> open)
    {
        Bounds = bounds; FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        BackColor = SystemColors.Window; ForeColor = SystemColors.WindowText;
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new Padding(24) };
        body.RowStyles.Add(new RowStyle(SizeType.Percent, 40));
        body.RowStyles.Add(new RowStyle(SizeType.Absolute, 45));
        body.RowStyles.Add(new RowStyle(SizeType.Absolute, 85));
        body.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        body.RowStyles.Add(new RowStyle(SizeType.Percent, 60));
        body.Controls.Add(new Label { Text = "Сейчас время работы", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Segoe UI", 22) }, 0, 1);
        body.Controls.Add(countdown, 0, 2);
        foreach (var app in allowed)
        {
            var button = new Button { Text = app.Name, AutoSize = true, MinimumSize = new Size(250, 36), UseVisualStyleBackColor = true };
            button.Click += (_, _) => open(app); buttons.Controls.Add(button);
        }
        body.Controls.Add(buttons, 0, 3); Controls.Add(body);
        FormClosing += (_, e) => e.Cancel = true;
    }
    public void UpdateCountdown(string value) => countdown.Text = value;
}

public sealed class ApplicationEnforcer : IDisposable
{
    private readonly List<ShieldForm> shields = [];
    private AppBookmark[] allowed = [];
    private nint lastAllowed;
    private long lastRedirect = -10_000;
    private bool checking;
    private readonly Native.WinEventProc callback;
    private readonly nint hook;
    public bool IsCovered => shields.Count > 0;
    public Func<bool> MenuVisible { get; set; } = () => false;
    public Func<string> Countdown { get; set; } = () => "";
    public event Action<AppBookmark>? OpenRequested;
    public event Action? ForegroundChanged;
    public ApplicationEnforcer()
    {
        callback = (_, _, _, _, _, _, _) => ForegroundChanged?.Invoke();
        hook = Native.SetWinEventHook(3, 3, 0, callback, 0, 0, 2); // EVENT_SYSTEM_FOREGROUND, skip own process
    }
    public void Start(IEnumerable<AppBookmark> apps)
    {
        allowed = ApplicationPolicy.Unique(apps); lastAllowed = 0; lastRedirect = -10_000;
        Cover();
        var all = DesktopService.Snapshot(allowed);
        foreach (var app in all.Where(a => !ApplicationPolicy.Allows(allowed, a.Bookmark)))
            foreach (var window in app.Windows) Native.ShowWindowAsync(window, 6);
        var first = all.FirstOrDefault(a => ApplicationPolicy.Allows(allowed, a.Bookmark))?.Windows.FirstOrDefault() ?? 0;
        if (first != 0) DesktopService.Raise(first);
    }
    public void Check()
    {
        if (allowed.Length == 0 || checking) return;
        checking = true;
        try
        {
            var foreground = Native.GetForegroundWindow();
            if (DesktopService.IsOwnWindow(foreground) && MenuVisible()) return;
            if (!DesktopService.IsOwnWindow(foreground) && ApplicationPolicy.Allows(allowed, DesktopService.Identify(foreground)))
            {
                lastAllowed = foreground; HideShields(); return;
            }
            Cover();
            var now = (long)Native.GetTickCount64();
            if (now - lastRedirect < 350) return;
            lastRedirect = now;
            if (foreground != 0 && !DesktopService.IsOwnWindow(foreground)) Native.ShowWindowAsync(foreground, 6);
            if (lastAllowed != 0 && ApplicationPolicy.Allows(allowed, DesktopService.Identify(lastAllowed))) DesktopService.Raise(lastAllowed);
            else
            {
                var target = DesktopService.Snapshot(allowed).FirstOrDefault(a => ApplicationPolicy.Allows(allowed, a.Bookmark))?.Windows.FirstOrDefault() ?? 0;
                if (target != 0) DesktopService.Raise(target);
            }
            // Keep the shield if Windows denies foreground activation; never assume success.
        }
        finally { checking = false; }
    }
    public void Cover()
    {
        var screens = Screen.AllScreens;
        if (shields.Count != screens.Length || shields.Where((form, index) => form.Bounds != screens[index].WorkingArea).Any())
        {
            HideShields();
            foreach (var screen in screens)
                shields.Add(new ShieldForm(screen.WorkingArea, allowed, app => OpenRequested?.Invoke(app)));
        }
        foreach (var shield in shields) { shield.UpdateCountdown(Countdown()); if (!shield.Visible) shield.Show(); }
    }
    private void HideShields() { foreach (var shield in shields) shield.Dispose(); shields.Clear(); }
    public void Stop() { allowed = []; lastAllowed = 0; HideShields(); }
    public void Dispose() { Stop(); if (hook != 0) Native.UnhookWinEvent(hook); GC.KeepAlive(callback); }
}
