using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using FocusTimer.Core;
using FocusTimer.Windows;

namespace FocusTimer.WindowsTests;

public static class PackageTests
{
    private static int checks;
    private static void Check(bool condition, string reason)
    { if (!condition) throw new Exception(reason); checks++; Console.WriteLine("PASS: " + reason); }
    private static void Wait(Func<bool> condition, string reason)
    {
        var until = Environment.TickCount64 + 15000;
        while (!condition() && Environment.TickCount64 < until) { Application.DoEvents(); Thread.Sleep(30); }
        Check(condition(), reason);
    }
    private static Process? Installed(string path) => Process.GetProcessesByName("FocusTimer")
        .FirstOrDefault(process => string.Equals(Native.ProcessPath((uint)process.Id), path, StringComparison.OrdinalIgnoreCase));
    private static Process Tool(string executable, string argument)
    {
        var process = Process.Start(new ProcessStartInfo(executable, argument) { UseShellExecute = false })!;
        Wait(() => process.HasExited, "command completed: " + argument); return process;
    }
    private static Process Install(string installer, string target)
    {
        var process = Process.Start(new ProcessStartInfo(installer) { UseShellExecute = true })!;
        Wait(() => Installed(target) is not null, "installed app started from permanent path");
        Wait(() => {
            var found = false;
            Native.EnumWindows((window, _) => {
                Native.GetWindowThreadProcessId(window, out var pid);
                if (pid != process.Id) return true;
                var name = new StringBuilder(100); Native.GetClassName(window, name, name.Capacity);
                if (name.ToString() != "#32770") return true;
                Native.PostMessage(window, 0x10, 0, 0); found = true; return false;
            }, 0);
            return found || process.HasExited;
        }, "installer success dialog acknowledged");
        Wait(() => process.HasExited, "installer exited normally"); Check(process.ExitCode == 0, "installer reported success");
        return Installed(target) ?? throw new Exception("Installed app is missing");
    }
    public static void Run(string distribution, string evidence)
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true")
            throw new InvalidOperationException("Package installation tests run only in a disposable GitHub Actions Windows VM.");
        Directory.CreateDirectory(evidence);
        var data = FocusTimer.Windows.Program.DataDirectory;
        var target = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "FocusTimer", "FocusTimer.exe");
        Check(!Directory.Exists(data) && !File.Exists(target), "fresh disposable runner has no existing Focus settings or installation");
        var store = new SettingsStore(Path.Combine(data, "settings.json"));
        var bookmark = new AppBookmark(Path.Combine(distribution, "FocusTimer.exe"), "Fixture selection");
        store.Save(new FocusSettings { Minutes = 37, Selection = [bookmark] });
        var original = File.ReadAllBytes(store.Path);
        using var preflight = Tool(Path.Combine(distribution, "FocusTimer.exe"), "--check-install");
        Check(preflight.ExitCode == 0, "published self-contained application starts and passes preflight");
        using var first = Install(Path.Combine(distribution, "InstallFocus.exe"), target);
        Check(original.SequenceEqual(File.ReadAllBytes(store.Path)), "installation preserves minutes and selection byte for byte");
        using var second = Process.Start(new ProcessStartInfo(Path.Combine(distribution, "InstallFocus.exe")) { UseShellExecute = true })!;
        Wait(() => first.HasExited, "updater requests ordinary exit from idle installed app");
        Wait(() => { var current = Installed(target); return current is not null && current.Id != first.Id; }, "updater starts new installed process");
        Wait(() => {
            Native.EnumWindows((window, _) => {
                Native.GetWindowThreadProcessId(window, out var pid);
                if (pid == second.Id) Native.PostMessage(window, 0x10, 0, 0);
                return true;
            }, 0);
            return second.HasExited;
        }, "updated installer closed normally");
        Check(second.ExitCode == 0, "idle update succeeded");
        Check(original.SequenceEqual(File.ReadAllBytes(store.Path)), "idle update preserves settings byte for byte");
        Check(Directory.GetDirectories(Path.GetDirectoryName(Path.GetDirectoryName(target))!, "FocusTimer.previous-*").Length == 1, "previous installation backed up");
        using var current = Installed(target) ?? throw new Exception("Missing updated app");
        using var quit = Tool(Path.Combine(distribution, "FocusTimer.exe"), "--request-exit");
        Check(quit.ExitCode == 0, "ordinary exit signal accepted for idle app"); Wait(() => current.HasExited, "idle installed app exited normally");
        // This is a test record in an empty CI profile; no protected timer is launched.
        var session = FocusSession.Start(1, [bookmark], WindowsClock.Read());
        store.Save(store.Load() with { Session = session });
        var activeBytes = File.ReadAllBytes(store.Path);
        var binaryHash = SHA256.HashData(File.ReadAllBytes(target));
        using var rejected = Tool(Path.Combine(distribution, "FocusTimer.exe"), "--install");
        Check(rejected.ExitCode == 3, "updater rejects saved unfinished session");
        Check(activeBytes.SequenceEqual(File.ReadAllBytes(store.Path)), "rejected update preserves active deadlines byte for byte");
        Check(binaryHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(target))), "rejected update leaves installed executable intact");
        File.WriteAllText(Path.Combine(evidence, "package-result.txt"), $"PASS: {checks} self-contained startup and real installer/update checks\n");
        Console.WriteLine($"PASS: {checks} self-contained startup and real installer/update checks");
    }
}
