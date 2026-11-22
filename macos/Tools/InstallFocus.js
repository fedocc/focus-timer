// JavaScript for Automation, run by the macOS osascript tool. No third-party runtime.
function assertIdleSettings(value) {
    if (value === null) return;
    if (typeof value !== "object" || Array.isArray(value) || (value.version !== 1 && value.version !== 2)) {
        throw new Error("Не удалось проверить сохраненный таймер. Установка остановлена.");
    }
    if (value.session !== null && value.session !== undefined) {
        throw new Error("Есть незавершенный блок. Откройте старый «Фокус», дождитесь окончания таймера и повторите установку.");
    }
}

function closeIdleApplications(apps, platform, attempts) {
    platform.checkIdle();
    for (var i = 0; i < apps.length; i++) {
        if (!apps[i].terminated) {
            // A false return can also mean the process exited between discovery and this request.
            // Confirmation happens after the run loop processes its termination notification.
            platform.requestQuit(apps[i]);
        }
    }
    for (var turn = 0; turn < attempts; turn++) {
        platform.checkIdle();
        if (apps.every(function (app) { return app.terminated; })) {
            platform.checkIdle();
            return;
        }
        platform.pump();
    }
    platform.checkIdle();
    if (apps.every(function (app) { return app.terminated; })) return;
    throw new Error("«Фокус» не подтвердил обычный выход. Откройте его меню, нажмите «Выйти» и повторите установку. Это сообщение не означает, что запущен таймер.");
}

function processNativeEvents() {
    // NSRunningApplication caches time-varying properties until a main-run-loop turn.
    // Sleeping the thread prevents isTerminated from updating.
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
}

function run(arguments) {
    if (arguments[0] === "self-test") {
        var passed = 0;
        [null, {version: 1}, {version: 1, session: null}, {version: 2, session: null}].forEach(function (value) {
            assertIdleSettings(value);
            passed++;
        });
        [[], "invalid", {version: 3}, {version: 1, session: {}}, {version: 2, session: {}},
         {version: 1, session: {wallDeadline: 1}}].forEach(function (value) {
            var rejected = false;
            try { assertIdleSettings(value); } catch (_) { rejected = true; }
            if (!rejected) throw new Error("Installer did not reject an active or unreadable timer");
            passed++;
        });
        function check(condition, reason) {
            if (!condition) throw new Error(reason);
            passed++;
        }
        var first = {terminated: false};
        var pumps = 0;
        var requests = 0;
        closeIdleApplications([first], {
            checkIdle: function () {},
            requestQuit: function () { requests++; return true; },
            pump: function () { pumps++; if (pumps === 2) first.terminated = true; }
        }, 4);
        check(requests === 1 && pumps === 2, "A delayed quit must be confirmed by processing events");
        var raced = {terminated: false};
        closeIdleApplications([raced], {
            checkIdle: function () {}, requestQuit: function () { return false; },
            pump: function () { raced.terminated = true; }
        }, 2);
        check(raced.terminated, "An already-exiting process must not be reported as refusing to quit");
        closeIdleApplications([], {
            checkIdle: function () {},
            requestQuit: function () { throw new Error("No app should receive quit"); },
            pump: function () { throw new Error("No wait is needed"); }
        }, 2);
        passed++;
        var unchanged = {terminated: false};
        var timeoutRejected = false;
        try {
            closeIdleApplications([unchanged], {
                checkIdle: function () {}, requestQuit: function () { return true; }, pump: function () {}
            }, 2);
        } catch (error) { timeoutRejected = String(error).indexOf("не подтвердил обычный выход") !== -1; }
        check(timeoutRejected && !unchanged.terminated, "Timeout must fail safely without killing the app");
        var blocked = false;
        try {
            closeIdleApplications([{terminated: false}], {
                checkIdle: function () { assertIdleSettings({version: 1, session: {}}); },
                requestQuit: function () { throw new Error("Active sessions must never receive a quit request"); },
                pump: function () {}
            }, 2);
        } catch (error) { blocked = String(error).indexOf("незавершенный блок") !== -1; }
        check(blocked, "An active block must stop installation before requesting quit");
        var turns = 0;
        var raceBlocked = false;
        try {
            closeIdleApplications([{terminated: false}], {
                checkIdle: function () { if (turns > 0) assertIdleSettings({version: 1, session: {}}); },
                requestQuit: function () { return true; }, pump: function () { turns++; }
            }, 3);
        } catch (error) { raceBlocked = String(error).indexOf("незавершенный блок") !== -1; }
        check(raceBlocked, "A newly started block must stop installation while waiting");
        return "PASS: " + passed + " installer session-safety and asynchronous-quit checks";
    }

    ObjC.import("AppKit");
    ObjC.import("Foundation");

    if (arguments[0] === "event-loop-test") {
        var eventDelivered = false;
        ObjC.registerSubclass({
            name: "FocusInstallerEventLoopProbe",
            superclass: "NSObject",
            methods: {
                "deliver:": {types: ["void", ["id"]], implementation: function (_) { eventDelivered = true; }}
            }
        });
        var probe = $.FocusInstallerEventLoopProbe.alloc.init;
        var timer = $.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(0.02, probe, "deliver:", $(), false);
        $.NSRunLoop.currentRunLoop.addTimerForMode(timer, $.NSDefaultRunLoopMode);
        processNativeEvents();
        if (!eventDelivered) throw new Error("The native run loop did not deliver its pending event");
        return "PASS: native event loop delivers pending events while waiting";
    }

    function checkSavedTimer() {
        var path = ObjC.unwrap($.NSHomeDirectory()) + "/Library/Application Support/FocusMenu/settings.json";
        if (!$.NSFileManager.defaultManager.fileExistsAtPath(path)) return;
        var data = $.NSData.dataWithContentsOfFile(path);
        if (!data) throw new Error("Не удалось прочитать сохраненный таймер.");
        var content = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
        if (!content) throw new Error("Не удалось прочитать сохраненный таймер.");
        assertIdleSettings(JSON.parse(ObjC.unwrap(content)));
    }

    var command = arguments[0];
    if (command === "preflight") {
        checkSavedTimer();
        return "Сохраненного активного блока нет.";
    }
    if (command === "running") {
        var rows = [];
        var running = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("local.fedor.focus-menu");
        for (var i = 0; i < running.count; i++) {
            var current = running.objectAtIndex(i);
            rows.push({pid: Number(current.processIdentifier), path: ObjC.unwrap(current.bundleURL.path)});
        }
        return JSON.stringify(rows);
    }
    if (command === "quit") {
        var runningApps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("local.fedor.focus-menu");
        var apps = [];
        for (var j = 0; j < runningApps.count; j++) apps.push(runningApps.objectAtIndex(j));
        closeIdleApplications(apps, {
            checkIdle: checkSavedTimer,
            requestQuit: function (app) { return app.terminate; },
            pump: processNativeEvents
        }, 80);
        return "Предыдущие копии закрыты.";
    }
    if (command === "reveal" && arguments.length === 2) {
        var url = $.NSURL.fileURLWithPath(arguments[1]);
        $.NSWorkspace.sharedWorkspace.activateFileViewerSelectingURLs($.NSArray.arrayWithObject(url));
        return arguments[1];
    }
    throw new Error("Неизвестная команда установщика.");
}
