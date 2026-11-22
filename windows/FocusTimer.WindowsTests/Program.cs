using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Runtime.InteropServices;
using FocusTimer.Core;
using FocusTimer.Windows;

namespace FocusTimer.WindowsTests;

public sealed record FixtureConfig(string Directory, string Role);
public sealed record FixtureState(int Pid, int Windows, bool PanelOpen, int Serial);
public sealed record FixtureCommand(int Serial, string Action, string? Path = null);

public static class Tests
{
    private static int checks;
    private static int serial;
    [STAThread]
    public static int Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2); Application.EnableVisualStyles();
        var configPath = Path.Combine(AppContext.BaseDirectory, "fixture-config.json");
        if (File.Exists(configPath))
        {
            var config = JsonSerializer.Deserialize<FixtureConfig>(File.ReadAllText(configPath))!;
            Application.Run(new FixtureForm(config)); return 0;
        }
        try {
            if (args is ["--package-test", var distribution, var evidence]) PackageTests.Run(Path.GetFullPath(distribution), Path.GetFullPath(evidence));
            else Run(args.Length > 0 ? Path.GetFullPath(args[0]) : Path.GetFullPath("artifacts/windows-tests"));
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
    private static void Check(bool condition, string reason)
    {
        if (!condition) throw new Exception(reason); checks++; Console.WriteLine("PASS: " + reason);
    }
    private static void Wait(Func<bool> condition, string reason, int milliseconds = 8000)
    {
        var deadline = Environment.TickCount64 + milliseconds;
        while (!condition() && Environment.TickCount64 < deadline) { Application.DoEvents(); Thread.Sleep(15); }
        Check(condition(), reason);
    }
    private static FixtureState? State(string folder, string role)
    {
        try { return JsonSerializer.Deserialize<FixtureState>(TestFiles.Read(Path.Combine(folder, role + "-state.json"))); }
        catch (IOException) { return null; }
    }
    private static void Command(string folder, string role, string action, string? path = null)
    {
        var next = ++serial;
        TestFiles.Write(Path.Combine(folder, role + "-command.json"), JsonSerializer.Serialize(new FixtureCommand(next, action, path)));
        Wait(() => State(folder, role)?.Serial == next, "fixture received " + action);
    }
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", EntryPoint = "mouse_event")] private static extern void MouseEvent(uint flags, uint x, uint y, uint data, nuint extra);
    private static IEnumerable<Control> Descendants(Control control) => control.Controls.Cast<Control>().SelectMany(child => new[] { child }.Concat(Descendants(child)));
    private static bool IsNativeDialog()
    {
        var kind = new StringBuilder(100);
        Native.GetClassName(Native.GetForegroundWindow(), kind, kind.Capacity);
        return kind.ToString() == "#32770";
    }
    private static void CheckFullyVisible(Control parent)
    {
        foreach (Control child in parent.Controls)
        {
            if (!child.Visible) continue;
            Check(child.Right <= parent.ClientSize.Width && child.Bottom <= parent.ClientSize.Height,
                "control fits native container: " + child.GetType().Name);
            CheckFullyVisible(child);
        }
    }
    private static void Capture(Form form, string path)
    {
        form.Show(); Application.DoEvents();
        using var bitmap = new Bitmap(form.Width, form.Height); form.DrawToBitmap(bitmap, form.ClientRectangle with { Width = form.Width, Height = form.Height });
        bitmap.Save(path); Console.WriteLine("Screenshot: " + path);
    }
    private static void Run(string folder)
    {
        Directory.CreateDirectory(folder);
        Console.WriteLine($"Windows {Environment.OSVersion}, interactive={Environment.UserInteractive}, session={Process.GetCurrentProcess().SessionId}");
        Check(WindowsClock.Read().BootId == WindowsClock.Read().BootId, "kernel boot identity stable");
        var store = new SettingsStore(Path.Combine(folder, "isolated-settings.json"));
        var a = new AppBookmark(@"C:\Fixture\Selected.exe", "Selected");
        var controller = new FocusController(store);
        controller.Select(a, true); controller.SetMinutes(37);
        Check(controller.Selection.Length == 1 && controller.Minutes == 37, "native controller saves preferences");
        using (var menu = new FocusMenu(controller))
        {
            menu.ShowNearTray(); Application.DoEvents();
            Check(menu.ClientSize.Width >= 350 && menu.ClientSize.Height >= 490, "menu dimensions fit native controls");
            CheckFullyVisible(menu);
            var selected = controller.Selection;
            menu.SetSearchForTest("selected"); Check(menu.VisibleAppCount == 1, "search finds saved closed app");
            menu.SetSearchForTest("missing-application"); Check(menu.VisibleAppCount == 0 && controller.Selection.SequenceEqual(selected), "search preserves hidden selections");
            menu.SetSearchForTest("");
            Capture(menu, Path.Combine(folder, "setup.png"));
            controller.Start(); var original = controller.Session!;
            Check(!controller.CanQuit, "active block rejects ordinary exit");
            controller.Select(new(@"C:\Fixture\Other.exe", "Other"), true); controller.SetMinutes(1); controller.Start();
            Check(controller.Session == original && controller.Minutes == 37 && controller.Selection.Length == 1, "selection, duration and timer cannot change during focus");
            var restored = new FocusController(store);
            Check(restored.Session!.Id == original.Id && restored.Session.UptimeDeadlineMs == original.UptimeDeadlineMs && restored.RemainingMs <= original.DurationMs, "process relaunch preserves active deadlines");
            menu.RenderState(); Capture(menu, Path.Combine(folder, "active.png")); menu.CloseForExit();
        }
        // The active record above belongs only to the test folder and no timer/enforcer was started.
        var shortSession = FocusSession.Start(1, [a], WindowsClock.Read()) with {
            DurationMs = 100, UptimeDeadlineMs = WindowsClock.Read().UptimeMs + 100,
            WallDeadline = DateTimeOffset.UtcNow.AddMilliseconds(100) };
        store.Save(new FocusSettings { Selection = [a], Session = shortSession });
        var shortController = new FocusController(store);
        Thread.Sleep(150); Check(shortController.Tick() && shortController.CanQuit && store.Load().Session is null, "elapsed test session finishes durably without cancellation");
        var ioSession = FocusSession.Start(1, [a], WindowsClock.Read()) with {
            DurationMs = 500, UptimeDeadlineMs = WindowsClock.Read().UptimeMs + 500,
            WallDeadline = DateTimeOffset.UtcNow.AddMilliseconds(500) };
        store.Save(new FocusSettings { Selection = [a], Session = ioSession });
        var ioController = new FocusController(store);
        File.Delete(store.Path); Directory.CreateDirectory(store.Path); // deterministic failure, test path only
        Thread.Sleep(600);
        Check(ioController.Tick() && ioController.CanQuit && ioController.PersistenceWarning is not null,
            "save failure cannot prolong an expired block");
        Directory.Delete(store.Path); store.Save(new FocusSettings());
        Native.AllowSetForegroundWindow(uint.MaxValue);
        var aPath = MakeFixture(folder, "a"); var bPath = MakeFixture(folder, "b");
        Process? allowedProcess = null; Process? deniedProcess = null;
        using var enforcer = new ApplicationEnforcer();
        try
        {
            allowedProcess = Process.Start(new ProcessStartInfo(aPath) { UseShellExecute = true })!;
            Wait(() => State(folder, "a") is not null, "allowed fixture launched");
            var bookmark = new AppBookmark(aPath, "Allowed fixture");
            enforcer.OpenRequested += DesktopService.Open;
            enforcer.Start([bookmark]);
            Command(folder, "a", "activate");
            Wait(() => ApplicationPolicy.Allows([bookmark], DesktopService.Identify(Native.GetForegroundWindow())), "permitted fixture is real foreground app");
            enforcer.Check(); Check(!enforcer.IsCovered, "permitted app has no shield");
            Command(folder, "a", "window");
            Wait(() => State(folder, "a")?.Windows == 2, "new window created in permitted process");
            enforcer.Check(); Check(!enforcer.IsCovered, "new window automatically allowed");
            Check(DesktopService.Snapshot().Count(x => x.Bookmark.Matches(bookmark)) == 1, "multiple windows yield one application row");
            foreach (var kind in new[] { "open", "save" })
            {
                Command(folder, "a", kind);
                Wait(() => State(folder, "a")?.PanelOpen == true && IsNativeDialog() && ApplicationPolicy.Allows([bookmark], DesktopService.Identify(Native.GetForegroundWindow())), "native " + kind + " dialog is frontmost");
                enforcer.Check(); Check(!enforcer.IsCovered, "native " + kind + " dialog allowed"); Command(folder, "a", "dismiss");
                Wait(() => State(folder, "a")?.PanelOpen == false, "native dialog dismissed");
            }
            Command(folder, "a", "launch", bPath);
            Wait(() => State(folder, "b") is not null, "separate app launched by selected program");
            deniedProcess = Process.GetProcessById(State(folder, "b")!.Pid);
            Command(folder, "b", "activate");
            var denied = new AppBookmark(bPath, "Denied fixture");
            Wait(() => ApplicationPolicy.Allows([denied], DesktopService.Identify(Native.GetForegroundWindow())), "unselected app foreground detected");
            enforcer.Check(); Check(enforcer.IsCovered, "unselected app covered immediately");
            var activationDeadline = Environment.TickCount64 + 1500;
            while (!ApplicationPolicy.Allows([bookmark], DesktopService.Identify(Native.GetForegroundWindow())) && Environment.TickCount64 < activationDeadline)
            { Application.DoEvents(); enforcer.Check(); Thread.Sleep(20); }
            if (!ApplicationPolicy.Allows([bookmark], DesktopService.Identify(Native.GetForegroundWindow())))
            {
                Check(enforcer.IsCovered, "Windows-denied activation retains the shield");
                Console.WriteLine("Windows refused automatic activation; testing a real click on the shield button");
                var shield = Application.OpenForms.OfType<ShieldForm>().First();
                var button = Descendants(shield).OfType<Button>().First();
                var point = button.PointToScreen(new Point(button.Width / 2, button.Height / 2));
                SetCursorPos(point.X, point.Y); MouseEvent(2, 0, 0, 0, 0); MouseEvent(4, 0, 0, 0, 0);
            }
            Wait(() => ApplicationPolicy.Allows([bookmark], DesktopService.Identify(Native.GetForegroundWindow())), "permitted app reachable after blocking, with native click recovery if needed");
            enforcer.Check(); Check(!enforcer.IsCovered, "shield removed after verified allowed foreground");
            var oldPid = allowedProcess.Id;
            Command(folder, "a", "quit"); Wait(() => allowedProcess.HasExited, "allowed app closed normally");
            File.Delete(Path.Combine(folder, "a-command.json")); File.Delete(Path.Combine(folder, "a-state.json"));
            DesktopService.Open(bookmark);
            Wait(() => State(folder, "a") is not null && State(folder, "a")!.Pid != oldPid, "selected app reopened with new PID");
            allowedProcess.Dispose(); allowedProcess = Process.GetProcessById(State(folder, "a")!.Pid);
            Command(folder, "a", "activate");
            Wait(() => ApplicationPolicy.Allows([bookmark], DesktopService.Identify(Native.GetForegroundWindow())), "relaunched app foreground");
            enforcer.Check(); Check(!enforcer.IsCovered, "new PID retains permission");
        }
        finally
        {
            enforcer.Stop();
            foreach (var (role, process) in new[] { ("a", allowedProcess), ("b", deniedProcess) })
            {
                if (process is null) continue;
                if (!process.HasExited) { Command(folder, role, "quit"); Wait(() => process.HasExited, "fixture " + role + " exited normally"); }
                process.Dispose();
            }
        }
        File.WriteAllText(Path.Combine(folder, "result.txt"), $"PASS: {checks} Windows controller, UI and foreground integration checks\n");
        Console.WriteLine($"PASS: {checks} Windows controller, UI and foreground integration checks");
    }
    private static string MakeFixture(string folder, string role)
    {
        var target = Path.Combine(folder, "fixture-" + role); Directory.CreateDirectory(target);
        foreach (var file in Directory.GetFiles(AppContext.BaseDirectory)) File.Copy(file, Path.Combine(target, Path.GetFileName(file)), true);
        File.WriteAllText(Path.Combine(target, "fixture-config.json"), JsonSerializer.Serialize(new FixtureConfig(folder, role)));
        return Path.Combine(target, Path.GetFileName(Environment.ProcessPath!));
    }
}

public sealed class FixtureForm : Form
{
    private readonly FixtureConfig config;
    private readonly List<Form> windows = [];
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 50 };
    private int serial = -1;
    private bool panel;
    public FixtureForm(FixtureConfig config)
    {
        this.config = config; Text = "Focus fixture " + config.Role; ClientSize = new Size(420, 250);
        Controls.Add(new Label { Text = "Disposable focus integration fixture", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter });
        Shown += (_, _) => { Activate(); timer.Start(); Poll(); };
        FormClosed += (_, _) => timer.Dispose(); timer.Tick += (_, _) => Poll();
    }
    private void WriteState()
    {
        TestFiles.Write(Path.Combine(config.Directory, config.Role + "-state.json"),
            JsonSerializer.Serialize(new FixtureState(Environment.ProcessId, windows.Count + 1, panel, serial)));
    }
    private void Poll()
    {
        var commandPath = Path.Combine(config.Directory, config.Role + "-command.json");
        FixtureCommand? command = null;
        try { if (File.Exists(commandPath)) command = JsonSerializer.Deserialize<FixtureCommand>(TestFiles.Read(commandPath)); }
        catch (IOException) { }
        catch (JsonException) { }
        if (command is not null && command.Serial != serial)
        {
            serial = command.Serial;
            switch (command.Action)
            {
                case "activate": Native.SetForegroundWindow(Handle); Activate(); break;
                case "window": var window = new Form { Text = "New fixture window", ClientSize = new Size(350, 220) }; windows.Add(window); window.Show(); window.Activate(); break;
                case "open":
                    panel = true; WriteState();
                    using (var dialog = new OpenFileDialog { InitialDirectory = config.Directory }) dialog.ShowDialog(this);
                    panel = false; break;
                case "save":
                    panel = true; WriteState();
                    using (var dialog = new SaveFileDialog { InitialDirectory = config.Directory }) dialog.ShowDialog(this);
                    panel = false; break;
                case "dismiss":
                    var foreground = Native.GetForegroundWindow(); var kind = new StringBuilder(100); Native.GetClassName(foreground, kind, kind.Capacity);
                    Native.GetWindowThreadProcessId(foreground, out var pid);
                    if (kind.ToString() == "#32770" && pid == Environment.ProcessId) Native.PostMessage(foreground, 0x10, 0, 0);
                    break;
                case "launch": Process.Start(new ProcessStartInfo(command.Path!) { UseShellExecute = true }); break;
                case "quit": Application.Exit(); break;
            }
        }
        WriteState();
    }
}

public static class TestFiles
{
    public static string Read(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream); return reader.ReadToEnd();
    }
    public static void Write(string path, string content)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(temporary, content); File.Move(temporary, path, true);
    }
}
