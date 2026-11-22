using System.Diagnostics;
using System.Text.Json;
using FocusTimer.Core;

namespace FocusTimer.Windows;

public static class WindowsInstaller
{
    public static string Install()
    {
        var store = new SettingsStore(Path.Combine(Program.DataDirectory, "settings.json"));
        InstallerPolicy.Check(store.Load());
        var source = Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
        var parent = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs");
        var target = Path.Combine(parent, "FocusTimer");
        if (string.Equals(source, target, StringComparison.OrdinalIgnoreCase)) return Path.Combine(target, "FocusTimer.exe");
        if (!File.Exists(Path.Combine(source, "FocusTimer.exe"))) throw new FileNotFoundException("Распакуйте весь архив перед установкой.");
        RequestIdleExit(store);
        Directory.CreateDirectory(Program.DataDirectory); Directory.CreateDirectory(parent);
        using (var instance = new FileStream(Path.Combine(Program.DataDirectory, "instance.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
        {
            InstallerPolicy.Check(store.Load());
            var staging = Path.Combine(parent, ".FocusTimer-new-" + Guid.NewGuid().ToString("N"));
            string? backup = null;
            try
            {
                CopyDistribution(source, staging);
                InstallerPolicy.Check(store.Load());
                if (Directory.Exists(target))
                {
                    backup = Path.Combine(parent, "FocusTimer.previous-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..6]);
                    Directory.Move(target, backup);
                }
                Directory.Move(staging, target);
            }
            catch
            {
                if (backup is not null && !Directory.Exists(target)) Directory.Move(backup, target);
                throw;
            }
            finally { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
        }
        var executable = Path.Combine(target, "FocusTimer.exe");
        ShellShortcut.Create(executable);
        return executable;
    }
    public static void RequestIdleExit(SettingsStore store)
    {
        var deadline = Environment.TickCount64 + 10_000;
        using var self = Process.GetCurrentProcess();
        while (true)
        {
            InstallerPolicy.Check(store.Load());
            var processes = Process.GetProcessesByName("FocusTimer");
            bool running;
            try { running = processes.Any(p => p.Id != Environment.ProcessId && p.SessionId == self.SessionId && !p.HasExited); }
            finally { foreach (var process in processes) process.Dispose(); }
            if (!running) { InstallerPolicy.Check(store.Load()); return; }
            // A new process can exist before its event/message loop is ready. Retry without killing it.
            if (EventWaitHandle.TryOpenExisting(Program.ExitEventName, out var request)) { using (request) request.Set(); }
            if (Environment.TickCount64 >= deadline)
                throw new IOException("Старая копия не подтвердила обычный выход. Дождитесь окончания блока и закройте ее через меню.");
            Thread.Sleep(100);
        }
    }
    private static void CopyDistribution(string source, string destination)
    {
        var manifest = Path.Combine(source, "distribution-files.json");
        var files = JsonSerializer.Deserialize<string[]>(File.ReadAllText(manifest))
            ?? throw new InvalidDataException("Не удалось прочитать список файлов выпуска.");
        Directory.CreateDirectory(destination);
        foreach (var relative in files.Append("distribution-files.json"))
        {
            var input = Path.GetFullPath(Path.Combine(source, relative));
            var output = Path.GetFullPath(Path.Combine(destination, relative));
            if (Path.IsPathRooted(relative) || !input.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                || !output.StartsWith(destination + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Некорректный путь в списке файлов выпуска.");
            Directory.CreateDirectory(Path.GetDirectoryName(output)!);
            File.Copy(input, output, true);
        }
    }
}
