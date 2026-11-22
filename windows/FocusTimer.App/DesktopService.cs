using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FocusTimer.Core;

namespace FocusTimer.Windows;

public sealed record LiveApp(AppBookmark Bookmark, nint[] Windows);

public static class WindowsClock
{
    private static readonly string BootId = ReadBootId();
    private static string ReadBootId()
    {
        // The kernel boot GUID is independent of process lifetime and wall-clock changes.
        var result = Native.NtQuerySystemInformation(90, out var boot, Marshal.SizeOf<Native.BootEnvironment>(), out _);
        if (result < 0 || boot.Id == Guid.Empty) throw new InvalidOperationException("Не удалось получить идентификатор загрузки Windows.");
        return boot.Id.ToString("D");
    }
    public static ClockReading Read() => new(DateTimeOffset.UtcNow, checked((long)Native.GetTickCount64()), BootId);
}

public static class DesktopService
{
    private static readonly Dictionary<string, string> Names = new(StringComparer.OrdinalIgnoreCase);
    public static AppBookmark? Identify(nint window)
    {
        if (window == 0) return null;
        Native.GetWindowThreadProcessId(window, out var pid);
        var path = Native.ProcessPath(pid);
        // Classic packaged/UWP applications can have an ApplicationFrameHost container.
        if (string.Equals(System.IO.Path.GetFileName(path), "ApplicationFrameHost.exe", StringComparison.OrdinalIgnoreCase))
        {
            Native.EnumChildWindows(window, (child, _) => {
                Native.GetWindowThreadProcessId(child, out var childPid);
                if (childPid == pid) return true;
                var childPath = Native.ProcessPath(childPid);
                if (childPath is null) return true;
                path = childPath; return false;
            }, 0);
        }
        return path is null ? null : new AppBookmark(path, DisplayName(path));
    }
    private static string DisplayName(string path)
    {
        if (Names.TryGetValue(path, out var name)) return name;
        try { name = FileVersionInfo.GetVersionInfo(path).FileDescription; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { name = null; }
        name = string.IsNullOrWhiteSpace(name) ? System.IO.Path.GetFileNameWithoutExtension(path) : name;
        Names[path] = name;
        return name;
    }
    public static bool IsOwnWindow(nint window)
    {
        Native.GetWindowThreadProcessId(window, out var pid);
        return pid == Environment.ProcessId;
    }
    public static LiveApp[] Snapshot(IEnumerable<AppBookmark>? saved = null)
    {
        var groups = new Dictionary<string, (AppBookmark App, List<nint> Windows)>(StringComparer.OrdinalIgnoreCase);
        Native.EnumWindows((window, _) => {
            if (!Native.IsWindowVisible(window) || IsOwnWindow(window)) return true;
            var title = new StringBuilder(512); Native.GetWindowText(window, title, title.Capacity);
            if (title.Length == 0) return true;
            var app = Identify(window);
            if (app is null || !app.IsValid) return true;
            if (!groups.TryGetValue(app.Id, out var group)) group = (app, []);
            group.Windows.Add(window); groups[app.Id] = group;
            return true;
        }, 0);
        foreach (var app in saved ?? []) if (!groups.ContainsKey(app.Id)) groups[app.Id] = (app, []);
        return groups.Values.OrderBy(a => a.App.Name, StringComparer.CurrentCultureIgnoreCase)
            .Select(a => new LiveApp(a.App, a.Windows.ToArray())).ToArray();
    }
    public static bool Raise(nint window)
    {
        if (Native.IsIconic(window)) Native.ShowWindowAsync(window, 9); // SW_RESTORE
        return Native.SetForegroundWindow(window);
    }
    public static void Open(AppBookmark bookmark)
    {
        if (!bookmark.IsValid || !File.Exists(bookmark.Path)) throw new FileNotFoundException("Приложение по сохраненному пути недоступно.", bookmark.Path);
        var existing = Snapshot([bookmark]).FirstOrDefault(a => a.Bookmark.Matches(bookmark))?.Windows.FirstOrDefault() ?? 0;
        if (existing != 0) { Raise(existing); return; }
        Process.Start(new ProcessStartInfo(bookmark.Path) { UseShellExecute = true });
    }
}
