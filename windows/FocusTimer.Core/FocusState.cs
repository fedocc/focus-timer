using System.Text.Json;

namespace FocusTimer.Core;

public sealed record AppBookmark(string Path, string Name)
{
    public string Id => Path.Replace('/', '\\').TrimEnd('\\').ToUpperInvariant();
    public bool IsValid => !string.IsNullOrWhiteSpace(Name) &&
        (Path.StartsWith(@"\\", StringComparison.Ordinal) ||
         (Path.Length > 3 && char.IsLetter(Path[0]) && Path[1] == ':' && (Path[2] == '\\' || Path[2] == '/'))) &&
        Path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
    public bool Matches(AppBookmark other) => IsValid && other.IsValid && Id == other.Id;
}

public readonly record struct ClockReading(DateTimeOffset WallUtc, long UptimeMs, string BootId);

public sealed record FocusSession
{
    public required Guid Id { get; init; }
    public required long DurationMs { get; init; }
    public required DateTimeOffset WallDeadline { get; init; }
    public required long UptimeDeadlineMs { get; init; }
    public required string BootId { get; init; }
    public required AppBookmark[] Applications { get; init; }

    public static FocusSession Start(int minutes, IEnumerable<AppBookmark> applications, ClockReading clock)
    {
        var chosen = ApplicationPolicy.Unique(applications);
        if (minutes is < 1 or > 720 || chosen.Length == 0 || chosen.Any(a => !a.IsValid))
            throw new InvalidDataException("Выберите приложения и время от 1 до 720 минут.");
        var duration = minutes * 60_000L;
        return new FocusSession { Id = Guid.NewGuid(), DurationMs = duration,
            WallDeadline = clock.WallUtc.AddMilliseconds(duration), UptimeDeadlineMs = checked(clock.UptimeMs + duration),
            BootId = clock.BootId, Applications = chosen };
    }
    public long RemainingMs(ClockReading clock) => Math.Clamp(BootId == clock.BootId
        ? UptimeDeadlineMs - clock.UptimeMs : (long)(WallDeadline - clock.WallUtc).TotalMilliseconds, 0, DurationMs);
    public bool IsValid => Id != Guid.Empty && DurationMs is > 0 and <= 43_200_000 &&
        UptimeDeadlineMs > 0 && !string.IsNullOrWhiteSpace(BootId) && Applications is { Length: > 0 } &&
        Applications.All(a => a is not null && a.IsValid);
}

public static class ApplicationPolicy
{
    public static AppBookmark[] Unique(IEnumerable<AppBookmark> apps) => apps.DistinctBy(a => a.Id).ToArray();
    public static bool Allows(IEnumerable<AppBookmark> chosen, AppBookmark? candidate) =>
        candidate is not null && chosen.Any(a => a.Matches(candidate));
    public static string Countdown(long milliseconds)
    {
        var seconds = (long)Math.Ceiling(Math.Max(0, milliseconds) / 1000.0);
        return seconds >= 3600 ? $"{seconds / 3600}:{seconds / 60 % 60:00}:{seconds % 60:00}"
            : $"{seconds / 60}:{seconds % 60:00}";
    }
}

public sealed record FocusSettings
{
    public int Version { get; init; } = 1;
    public int Minutes { get; init; } = 50;
    public AppBookmark[] Selection { get; init; } = [];
    public FocusSession? Session { get; init; }
    public bool IsValid => Version == 1 && Minutes is >= 1 and <= 720 && Selection is not null &&
        Selection.All(a => a is not null && a.IsValid) && (Session is null || Session.IsValid);
}

public sealed class SettingsStore(string path)
{
    public string Path { get; } = path;
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    public FocusSettings Load()
    {
        if (!File.Exists(Path)) return new();
        var info = new FileInfo(Path);
        if (info.Length > 1_048_576) throw new InvalidDataException("Файл таймера слишком большой.");
        using var stream = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var value = JsonSerializer.Deserialize<FocusSettings>(stream, Json);
        if (value is null || !value.IsValid) throw new InvalidDataException("Не удалось проверить сохраненный таймер.");
        return value;
    }
    public void Save(FocusSettings settings)
    {
        if (!settings.IsValid) throw new InvalidDataException("Недопустимое состояние таймера.");
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        var temporary = Path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, settings, Json);
                stream.Flush(true);
            }
            File.Move(temporary, Path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

public static class InstallerPolicy
{
    public static void Check(FocusSettings settings)
    {
        if (!settings.IsValid) throw new InvalidDataException("Не удалось проверить сохраненный таймер.");
        // Even an expired record must be finished by the app, never erased by an updater.
        if (settings.Session is not null) throw new InvalidOperationException("Дождитесь окончания блока в «Фокусе» и повторите установку.");
    }
}
