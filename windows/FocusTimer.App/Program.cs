using System.Text.Json;
using System.Diagnostics;
using FocusTimer.Core;

namespace FocusTimer.Windows;

public static class Program
{
    public const string ExitEventName = @"Local\FocusTimer.RequestExit";
    public static string DataDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FocusTimer");
    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            if (args is ["--install"] || (args.Length == 0 && string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "InstallFocus", StringComparison.OrdinalIgnoreCase)))
            {
                ApplicationConfiguration.Initialize();
                var installed = WindowsInstaller.Install();
                Process.Start(new ProcessStartInfo(installed) { UseShellExecute = true });
                MessageBox.Show("Установлено: «Фокус Таймер». Значок находится в области уведомлений рядом с часами.", "Фокус");
                return 0;
            }
            var store = new SettingsStore(Path.Combine(DataDirectory, "settings.json"));
            if (args is ["--check-install"]) { InstallerPolicy.Check(store.Load()); return 0; }
            if (args is ["--request-exit"])
            {
                WindowsInstaller.RequestIdleExit(store);
                return 0;
            }
            if (args is ["--status"])
            {
                var settings = store.Load();
                Console.WriteLine(JsonSerializer.Serialize(new { version = "1.3.0", applications = DesktopService.Snapshot().Length,
                    hasSavedSession = settings.Session is not null, bootId = WindowsClock.Read().BootId }));
                return 0;
            }
            if (args.Length > 0) return 2;
            ApplicationConfiguration.Initialize();
            Directory.CreateDirectory(DataDirectory);
            FileStream instance;
            try { instance = new FileStream(Path.Combine(DataDirectory, "instance.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) { MessageBox.Show("«Фокус» уже запущен. Откройте значок в области уведомлений.", "Фокус"); return 0; }
            using (instance)
            using (var context = new FocusContext(new FocusController(store))) Application.Run(context);
            return 0;
        }
        catch (Exception error)
        {
            if (args.Length > 0) { Console.Error.WriteLine(error.GetBaseException().Message); return error is InvalidOperationException ? 3 : 4; }
            MessageBox.Show(error.Message, "Не удалось запустить «Фокус»", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}

public sealed class FocusContext : ApplicationContext
{
    private readonly FocusController controller;
    private readonly FocusMenu menu;
    private readonly NotifyIcon tray;
    private readonly ApplicationEnforcer enforcer = new();
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 200 };
    private readonly EventWaitHandle exitRequest = new(false, EventResetMode.AutoReset, Program.ExitEventName);
    public FocusContext(FocusController controller)
    {
        this.controller = controller;
        menu = new FocusMenu(controller);
        var icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;
        var contextMenu = new ContextMenuStrip();
        contextMenu.Items.Add("Открыть «Фокус»", null, (_, _) => menu.ShowNearTray());
        var quit = contextMenu.Items.Add("Выйти", null, (_, _) => Quit());
        contextMenu.Opening += (_, _) => quit.Enabled = controller.CanQuit;
        tray = new NotifyIcon { Icon = icon, Text = "Фокус Таймер", Visible = true, ContextMenuStrip = contextMenu };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) menu.ShowNearTray(); };
        enforcer.MenuVisible = () => menu.Visible;
        enforcer.Countdown = () => ApplicationPolicy.Countdown(controller.RemainingMs);
        enforcer.OpenRequested += Open; enforcer.ForegroundChanged += Tick;
        menu.OpenRequested += Open;
        menu.QuitRequested += Quit;
        menu.StartRequested += () => {
            try { controller.Start(); enforcer.Start(controller.Session!.Applications); menu.Hide(); Tick(); }
            catch (Exception error) { menu.ShowError(error); }
        };
        controller.Changed += menu.RenderState;
        controller.Completed += () => {
            enforcer.Stop(); System.Media.SystemSounds.Asterisk.Play(); menu.ShowNearTray();
            if (controller.PersistenceWarning is string warning) menu.ShowError(new IOException(warning));
        };
        timer.Tick += (_, _) => {
            if (exitRequest.WaitOne(0) && controller.CanQuit) { Quit(); return; }
            Tick();
        };
        if (controller.Session is not null) enforcer.Start(controller.Session.Applications);
        else menu.ShowNearTray();
        timer.Start(); Tick();
    }
    private void Open(AppBookmark app)
    {
        if (controller.Session is null || !ApplicationPolicy.Allows(controller.Session.Applications, app)) return;
        try { DesktopService.Open(app); }
        catch (Exception error) { menu.ShowError(error); }
    }
    private void Tick()
    {
        try
        {
            controller.Tick();
            if (controller.Session is not null) enforcer.Check();
            tray.Text = controller.Session is null ? "Фокус Таймер" : "Фокус · " + ApplicationPolicy.Countdown(controller.RemainingMs);
            menu.UpdateCountdown();
        }
        catch (Exception error) { timer.Stop(); menu.ShowError(error); }
    }
    private void Quit() { if (controller.CanQuit) ExitThread(); }
    protected override void ExitThreadCore()
    {
        timer.Stop(); tray.Visible = false; enforcer.Dispose(); menu.CloseForExit(); base.ExitThreadCore();
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { timer.Dispose(); tray.Dispose(); enforcer.Dispose(); menu.Dispose(); exitRequest.Dispose(); }
        base.Dispose(disposing);
    }
}
