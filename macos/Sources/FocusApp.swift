import AppKit
import SwiftUI
import Darwin

struct ApplicationSearch: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(frame: .zero)
        field.placeholderString = "Поиск по приложениям"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.setAccessibilityLabel("Поиск по приложениям")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
        @objc func searchChanged(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
    }
}

struct ApplicationRow: View {
    let application: LiveApplication
    let selected: Bool
    var change: ((Bool) -> Void)?
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let change {
                Toggle(isOn: Binding(get: { selected }, set: change)) { details }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Разрешить приложение \(application.bookmark.appName)")
            } else {
                Button(action: { action?() }) {
                    HStack {
                        details
                        Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .help(application.bookmark.appPath)
    }

    private var details: some View {
        HStack(spacing: 10) {
            if let icon = application.icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26).accessibilityHidden(true)
            } else {
                Image(systemName: "app").font(.system(size: 23)).frame(width: 26).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(application.bookmark.appName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(application.isRunning ? "Все окна" : (change == nil ? "Не запущено · открыть" : "Не запущено"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
    }
}

struct FocusMenu: View {
    @ObservedObject var model: FocusModel
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Фокус", systemImage: model.session == nil ? "timer" : "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.session == nil {
                    Button(action: { model.refreshApplications() }) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Обновить приложения")
                }
            }.padding(.bottom, 16)

            if model.session != nil {
                active
            } else {
                setup
            }
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10).accessibilityLabel("Ошибка: \(message)")
            }
        }
        .padding(18)
        .frame(width: 352)
        .onChange(of: model.minutes) { model.saveIdlePreferences() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.completed ? "Блок завершен. Можно отдохнуть." : "Выберите приложения для работы")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            ApplicationSearch(text: $model.applicationQuery).frame(height: 24)

            if model.visibleApplications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app").font(.system(size: 25)).foregroundStyle(.tertiary)
                    Text(!model.applicationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Ничего не найдено"
                        : "Откройте нужные приложения")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 110)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleApplications) { application in
                            ApplicationRow(application: application, selected: model.selection.contains(application.id),
                                change: { model.setSelected(application, $0) })
                            if application.id != model.visibleApplications.last?.id { Divider().padding(.leading, 46) }
                        }
                    }
                }
                .frame(height: min(CGFloat(model.visibleApplications.count) * 53, 265))
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
            }

            HStack(spacing: 6) {
                Text("Время").font(.system(size: 13))
                Spacer()
                TextField("Минуты", value: $model.minutes, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 55)
                    .accessibilityLabel("Длительность в минутах")
                Text("мин").font(.system(size: 12)).foregroundStyle(.secondary)
                Stepper("Длительность", value: $model.minutes, in: 1...720)
                    .labelsHidden().fixedSize()
            }.padding(.top, 3)

            Button(action: model.start) {
                Text("Начать").frame(maxWidth: .infinity).padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            .disabled(!model.canStart)

            HStack {
                Text("До конца таймера без отмены")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Выйти", action: quit).font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
    }

    private var active: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 4) {
                Text(countdown(model.remaining))
                    .font(.system(size: 45, weight: .light, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("Осталось для работы").font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 5)
            Divider()
            Text("Разрешенные приложения").font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.allowedApplications) { application in
                        ApplicationRow(application: application, selected: true, action: { model.focus(application) })
                    }
                    if model.allowedApplications.isEmpty {
                        Text("Приложения закрыты. Нажмите, чтобы открыть.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                }
            }.frame(height: min(max(53, CGFloat(model.allowedApplications.count) * 53), 212))
            Text("Все окна выбранных приложений разрешены.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

struct ShieldContent: View {
    @ObservedObject var model: FocusModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.system(size: 25, weight: .light)).foregroundStyle(.secondary)
            Text("Сейчас время работы").font(.system(size: 24, weight: .medium))
            Text(countdown(model.remaining)).font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
            ForEach(model.allowedApplications) { application in
                Button(application.bookmark.appName + (application.isRunning ? "" : " · открыть")) {
                    model.focus(application)
                }.buttonStyle(.bordered).lineLimit(1).frame(maxWidth: 420)
            }
            if model.allowedApplications.isEmpty {
                Text("Разрешенные приложения недоступны. Таймер продолжает идти.").foregroundStyle(.secondary)
            }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var model: FocusModel!
    var status: NSStatusItem!
    let popover = NSPopover()
    var monitor: Any?
    var lockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusMenu", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            lockFD = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                NSApp.terminate(nil)
                return
            }
        } catch { showFatal(error); return }

        model = FocusModel(store: SettingsStore(url: directory.appendingPathComponent("settings.json")))
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Фокус")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let controller = NSHostingController(rootView: FocusMenu(model: model, quit: { NSApp.terminate(nil) }))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        model.isPopoverShown = { [weak self] in self?.popover.isShown ?? false }
        model.enforcer.shieldView = { [weak model] in
            guard let model else { return NSView() }
            return NSHostingView(rootView: ShieldContent(model: model))
        }
        model.onStatusChange = { [weak self] in self?.updateStatus() }
        model.onStart = { [weak self] in self?.popover.performClose(nil) }
        model.onComplete = { [weak self] in self?.showPopover() }
        model.launch()
        updateStatus()
        if model.session == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showPopover() } }
    }

    func showFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Не удалось запустить «Фокус»"
        alert.informativeText = error.localizedDescription
        alert.runModal()
        NSApp.terminate(nil)
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    func showPopover() {
        guard let button = status?.button else { return }
        model.refreshApplications()
        if let view = popover.contentViewController?.view { popover.contentSize = view.fittingSize }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) { model.tick() }

    func updateStatus() {
        guard let button = status?.button else { return }
        let title = model.session == nil ? "" : " " + countdown(model.remaining)
        if button.title != title { button.title = title }
        button.toolTip = model.session == nil ? "Фокус — выбрать приложения и время" : "Фокус · осталось " + countdown(model.remaining)
        button.setAccessibilityLabel(button.toolTip)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.session == nil else { return .terminateCancel }
        model?.saveIdlePreferences()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

#if !FOCUS_UI_TEST
@main
enum FocusMain {
    static func main() {
        if CommandLine.arguments.contains("--status") {
            let value: [String: Any] = ["requiresAccessibility": false,
                "applications": ApplicationService.snapshot(excluding: getpid()).count,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
