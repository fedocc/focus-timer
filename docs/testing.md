# Проверки

## macOS

Ядро: таймер, изменение системных часов, восстановление после перезагрузки,
миграция старых окон в приложения без изменения сроков таймера. Нативные UI-тесты
проверяют поиск, скрытые галочки и запрет обычного выхода во время блока.

Интеграционный тест запускает две временные GUI-программы на Mac: новые окна,
NSOpenPanel, NSSavePanel, блокировку отдельной программы и новый PID после
перезапуска. Рабочие настройки и защищенный таймер пользователя не используются.

## Windows

Тесты ядра можно запускать на любой ОС с .NET 10. Нативные интеграционные тесты
требуют Windows с оконным рабочим столом. Они создают изолированные настройки,
проверяют формы и сохраняют снимки setup/active. Затем запускают две тестовые
программы: новые окна выбранной программы, настоящие OpenFileDialog/SaveFileDialog,
отдельный запрещенный `.exe`, перенаправление и повторный запуск выбранного `.exe`.

В GitHub Actions используется Windows Server 2025 x64. Ошибка интеграционного теста
останавливает упаковку: отсутствие настоящего рабочего стола не считается успехом.
Снимки и журнал загружаются как `windows-test-evidence`, в том числе при ошибке.
Windows ARM64 собирается отдельно, оконные тесты на ARM64 пока не выполняются.

Системные ограничения SetForegroundWindow означают, что Windows может отклонить
автоматическую активацию другого процесса. В этом случае экран защиты остается
до подтвержденного перехода к разрешенному приложению.

## Источники решений

- [Microsoft: сборка Windows на другой ОС и ограничения выпуска](https://learn.microsoft.com/en-us/dotnet/core/project-sdk/msbuild-props#enablewindowstargeting).
- [Microsoft: self-contained deployment](https://learn.microsoft.com/en-us/dotnet/core/deploying/).
- [Microsoft: GetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getforegroundwindow).
- [Microsoft: ограничения SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow).
- [Microsoft: GetTickCount64 включает сон и гибернацию](https://learn.microsoft.com/en-us/windows/win32/sysinfo/windows-time).
- [Microsoft: NtQuerySystemInformation может меняться между версиями](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation).
- [GitHub: Windows hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Идентификатор загрузки Windows берется из boot GUID ядра. Если получить его
не удается, новый таймер не запускается: приложение показывает ошибку, вместо
догадки о том, перезагружалась ли система. Для uptime явно вызывается GetTickCount64,
чтобы время сна учитывалось независимо от изменений Environment.TickCount64 в .NET.
