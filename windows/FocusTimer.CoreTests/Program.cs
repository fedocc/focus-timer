using FocusTimer.Core;

var count = 0;
void Check(bool condition, string reason) { if (!condition) throw new Exception(reason); count++; }
void Reject(Action action, string reason) { try { action(); } catch { count++; return; } throw new Exception(reason); }
var a = new AppBookmark(@"C:\Apps\Editor.exe", "Editor");
var b = new AppBookmark(@"C:\Apps\Other.exe", "Other");
var clock = new ClockReading(DateTimeOffset.FromUnixTimeSeconds(10000), 100000, "boot-a");
var session = FocusSession.Start(2, [a], clock);
Check(session.RemainingMs(clock) == 120000, "full duration");
Check(session.RemainingMs(clock with { UptimeMs = 160000 }) == 60000, "continuous timer");
Check(session.RemainingMs(clock with { UptimeMs = 160000, WallUtc = clock.WallUtc.AddDays(-1) }) == 60000, "wall rewind cannot extend same-boot timer");
Check(session.RemainingMs(clock with { UptimeMs = 160000, WallUtc = clock.WallUtc.AddDays(1) }) == 60000, "wall forward cannot finish same-boot timer");
Check(session.RemainingMs(clock with { UptimeMs = 220000 }) == 0, "expiry boundary");
Check(session.RemainingMs(clock with { UptimeMs = 600000 }) == 0, "sleep included in uptime input");
Check(session.RemainingMs(clock with { BootId = "boot-b", UptimeMs = 10, WallUtc = clock.WallUtc.AddSeconds(60) }) == 60000, "reboot uses original wall deadline");
Check(session.RemainingMs(clock with { BootId = "boot-b", UptimeMs = 10, WallUtc = clock.WallUtc.AddDays(-1) }) == 120000, "reboot caps remaining time");
Check(ApplicationPolicy.Allows([a], a with { Path = @"c:\APPS\editor.EXE", Name = "Renamed" }), "case insensitive exe identity independent of name");
Check(!ApplicationPolicy.Allows([a], b), "Explorer or another selected program cannot grant other exe");
Check(!ApplicationPolicy.Allows([a], a with { Path = @"C:\Different\Editor.exe" }), "different installed copy denied");
Check(!ApplicationPolicy.Allows([a], null), "unknown foreground denied");
Check(ApplicationPolicy.Unique([a, a, b, a]).Length == 2, "one app despite multiple windows or PIDs");
foreach (var duration in new[] { -1, 0, 721 }) Reject(() => FocusSession.Start(duration, [a], clock), "invalid duration");
Reject(() => FocusSession.Start(1, [], clock), "empty selection");
Reject(() => FocusSession.Start(1, [new("relative.exe", "Relative")], clock), "relative path rejected");
Check(ApplicationPolicy.Countdown(60001) == "1:01", "ceil fractional seconds");
Check(ApplicationPolicy.Countdown(3601000) == "1:00:01", "hour formatting");
Check(ApplicationPolicy.Countdown(-1) == "0:00", "zero formatting");
var directory = Path.Combine(Path.GetTempPath(), "focus-core-tests-" + Guid.NewGuid().ToString("N"));
var store = new SettingsStore(Path.Combine(directory, "settings.json"));
try
{
    Check(store.Load() == new FocusSettings(), "missing state defaults");
    var settings = new FocusSettings { Minutes = 37, Selection = [a, b], Session = session };
    store.Save(settings);
    var saved = File.ReadAllBytes(store.Path);
    var loaded = store.Load();
    Check(loaded.Minutes == 37 && loaded.Selection.SequenceEqual([a, b]), "preferences roundtrip");
    Check(loaded.Session!.Id == session.Id && loaded.Session.WallDeadline == session.WallDeadline && loaded.Session.UptimeDeadlineMs == session.UptimeDeadlineMs, "deadlines and ID immutable across relaunch");
    Check(loaded.Session.RemainingMs(clock with { UptimeMs = 160000 }) == 60000, "restored countdown resumes");
    Check(saved.SequenceEqual(File.ReadAllBytes(store.Path)), "load never changes existing state");
    Reject(() => InstallerPolicy.Check(loaded), "installer must reject active block");
    Reject(() => InstallerPolicy.Check(loaded with { Session = session with { WallDeadline = DateTimeOffset.MinValue } }), "updater cannot erase even an expired session record");
    InstallerPolicy.Check(new()); count++;
    Reject(() => store.Save(settings with { Minutes = 0 }), "invalid state save rejected");
    Check(saved.SequenceEqual(File.ReadAllBytes(store.Path)), "failed save retains durable timer");
    File.WriteAllText(store.Path, "broken"); Reject(() => store.Load(), "corruption must not silently reset timer");
    File.WriteAllText(store.Path, "{\"version\":99}"); Reject(() => store.Load(), "unsupported schema rejected");
    File.WriteAllText(store.Path, "{\"session\":{}}"); Reject(() => store.Load(), "missing required deadlines rejected");
}
finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
Console.WriteLine($"PASS: {count} core, timer, persistence, app-policy and installer checks");
