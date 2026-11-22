using FocusTimer.Core;

namespace FocusTimer.Windows;

public sealed class FocusController
{
    private readonly SettingsStore store;
    private FocusSettings settings;
    public FocusSession? Session => settings.Session;
    public int Minutes => settings.Minutes;
    public AppBookmark[] Selection => settings.Selection.ToArray();
    public long RemainingMs => Session?.RemainingMs(WindowsClock.Read()) ?? 0;
    public string? PersistenceWarning { get; private set; }
    public bool CanQuit => Session is null;
    public event Action? Changed;
    public event Action? Completed;
    public FocusController(SettingsStore store)
    {
        this.store = store; settings = store.Load();
        if (Session is not null && RemainingMs == 0) Commit(settings with { Session = null });
    }
    private void Commit(FocusSettings next) { store.Save(next); settings = next; Changed?.Invoke(); }
    public void Select(AppBookmark app, bool selected)
    {
        if (Session is not null) return;
        Commit(settings with { Selection = selected ? ApplicationPolicy.Unique(settings.Selection.Append(app))
            : settings.Selection.Where(a => !a.Matches(app)).ToArray() });
    }
    public void SetMinutes(int minutes)
    {
        if (Session is not null) return;
        if (minutes is < 1 or > 720) throw new ArgumentOutOfRangeException(nameof(minutes));
        Commit(settings with { Minutes = minutes });
    }
    public void Start()
    {
        if (Session is not null) return;
        var session = FocusSession.Start(Minutes, Selection, WindowsClock.Read());
        Commit(settings with { Session = session });
    }
    public bool Tick()
    {
        if (Session is null || RemainingMs > 0) return false;
        var finished = settings with { Session = null };
        try { store.Save(finished); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { PersistenceWarning = "Блок завершен, но не удалось сохранить результат: " + error.Message; }
        settings = finished; Changed?.Invoke(); Completed?.Invoke(); return true;
    }
}
