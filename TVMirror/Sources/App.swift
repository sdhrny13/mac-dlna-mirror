import AppKit
import ScreenCaptureKit
import SwiftUI

enum Phase { case idle, starting, streaming }

struct DisplayItem: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

extension Loc {
    static let ready = Loc("Ready to stream", "Готово к трансляции")
    static let tvNotFound = Loc("TV not found", "Телевизор не найден")
    static let noNetwork = Loc("No Local Network access", "Нет доступа к локальной сети")
    static let streaming = Loc("Streaming", "Идёт трансляция")
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var tvs: [TV] = []
    @Published var selectedTV: String? { didSet { defaults.set(selectedTV, forKey: "lastTV") } }
    @Published var discovering = false
    @Published var manualIP = ""
    @Published var height: Int { didSet { defaults.set(height, forKey: "height") } }
    @Published var fps60: Bool { didSet { defaults.set(fps60, forKey: "fps60") } }
    @Published var audio: Bool { didSet { defaults.set(audio, forKey: "audio") } }
    @Published var reduceLatency: Bool { didSet { defaults.set(reduceLatency, forKey: "reduceLatency") } }
    /// true — "Second display" (virtual monitor), false — mirror the Mac screen.
    @Published var extend: Bool { didSet { defaults.set(extend, forKey: "extend") } }
    /// Interface language; changing it re-renders the window with the other set of strings.
    @Published var language: UILanguage {
        didSet { UILanguage.current = language; defaults.set(language.rawValue, forKey: UILanguage.key) }
    }
    @Published var catchingUp = false
    @Published var displays: [DisplayItem] = []
    @Published var displayID: CGDirectDisplayID = 0
    @Published var phase: Phase = .idle
    @Published var status = Loc.ready
    @Published var hint: Loc?
    @Published var latency: Double?
    @Published var statsLine = ""
    @Published var permissionProblem = false
    @Published var networkBlocked = false
    @Published var tvConnected = false

    let server = StreamServer()
    let engine: Engine
    private let defaults = UserDefaults.standard
    private var activeTV: TV?
    private var monitor: DLNALatency?
    private var timer: Timer?

    private init() {
        reduceLatency = defaults.object(forKey: "reduceLatency") as? Bool ?? true
        extend = defaults.bool(forKey: "extend")
        height = defaults.object(forKey: "height") as? Int ?? 1080
        fps60 = defaults.bool(forKey: "fps60")
        audio = defaults.object(forKey: "audio") as? Bool ?? true
        language = UILanguage.current
        selectedTV = defaults.string(forKey: "lastTV")
        engine = Engine(server: server)
        if let saved = savedTV { tvs = [saved] }
        do { try server.start() } catch {
            status = Loc("Server did not start: \(error.localizedDescription)", "Сервер не запустился: \(error.localizedDescription)")
        }
        server.onEvent = { [weak self] kind, remote in
            MainActor.assumeIsolated { self?.serverEvent(kind, remote) }
        }
        engine.onStopped = { [weak self] reason in
            DispatchQueue.main.async { self?.engineStopped(reason) }
        }
        Log.shared.onLine = { [weak self] _ in
            DispatchQueue.main.async { LogStore.shared.lineAdded() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        log("TVMirror 2.0, server on port \(server.port), screen recording allowed: \(CGPreflightScreenCaptureAccess() ? "yes" : "no")")
        loadDisplays()
        discover()
        // Back in the app (e.g. from System Settings) — if no TV has been found yet, search again.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .idle, self.tvs.isEmpty || self.networkBlocked else { return }
                self.discover()
            }
        }
    }

    private var savedTV: TV? {
        get { defaults.data(forKey: "savedTV").flatMap { try? JSONDecoder().decode(TV.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "savedTV") }
    }

    var selected: TV? { tvs.first { $0.id == selectedTV } }

    // MARK: discovery

    func discover() {
        guard !discovering else { return }
        discovering = true
        Task {
            var (found, blocked) = await DLNA.discoverDetailed()
            if let saved = savedTV, !found.contains(where: { $0.ip == saved.ip }), let tv = await DLNA.probe(ip: saved.ip) {
                found.append(tv)
            }
            for tv in tvs where !found.contains(where: { $0.ip == tv.ip }) && tv.ip == selectedTV && phase != .idle {
                found.append(tv)   // streaming is on — don't lose the selected TV
            }
            discovering = false
            tvs = found
            networkBlocked = blocked && found.isEmpty
            if selected == nil { selectedTV = tvs.first?.id }
            if networkBlocked {
                status = .noNetwork
                hint = nil
            } else if tvs.isEmpty {
                status = .tvNotFound
                hint = Loc("Make sure the TV is on and connected to the same Wi-Fi network as the Mac. You can also enter its IP by hand.",
                           "Проверьте, что ТВ включён и подключён к той же Wi-Fi сети, что и Mac. Можно ввести IP вручную.")
            } else if phase == .idle, status == .tvNotFound || status == .noNetwork {
                hint = nil
                status = .ready
            }
        }
    }

    func addManual() {
        let ip = manualIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        guard isPrivateIPv4(ip) else {
            status = Loc("Enter the TV's local IP address, e.g. 192.168.1.50", "Введите локальный IP-адрес телевизора, например 192.168.1.50")
            return
        }
        Task {
            guard let tv = await DLNA.probe(ip: ip) else {
                status = Loc("No TV answers at \(ip)", "По адресу \(ip) телевизор не отвечает")
                return
            }
            if !tvs.contains(where: { $0.ip == tv.ip }) { tvs.append(tv) }
            selectedTV = tv.id
            manualIP = ""
            hint = nil
            status = .ready
        }
    }

    func loadDisplays() {
        displays = NSScreen.screens.compactMap { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return DisplayItem(id: id, name: s.localizedName)
        }.filter { !$0.name.contains("TVMirror") }   // our own virtual monitor is not offered for mirroring
        if !displays.contains(where: { $0.id == displayID }) { displayID = CGMainDisplayID() }
    }

    // MARK: streaming

    func start() {
        guard phase == .idle else { return }
        guard let tv = selected else { status = Loc("Select a TV first", "Сначала выберите телевизор"); return }
        if tv.controlURL == nil {
            status = Loc("No DLNA player found on this TV", "У этого ТВ не найден DLNA-плеер")
            return
        }
        // Right after the permission is granted, CGPreflightScreenCaptureAccess often lies until the app restarts,
        // so we don't stop on it: we try to start capture and deal with the actual error.
        log("start: TV \(tv.ip), screen recording preflight: \(CGPreflightScreenCaptureAccess() ? "yes" : "no")")
        permissionProblem = false
        phase = .starting
        hint = nil
        latency = nil
        tvConnected = false
        status = Loc("Starting screen capture…", "Запускаю захват экрана…")
        activeTV = tv
        savedTV = tv
        let fps = fps60 ? 60 : 30
        var cfg = StreamConfig(displayID: displayID == 0 ? nil : displayID, height: height, fps: fps,
                               bitrate: StreamConfig.bitrate(height: height, fps: fps), audio: audio)
        cfg.extend = extend
        let extendMode = extend
        StreamServer.padBytesPerSecond = reduceLatency ? 1_000_000 : 0    // 8 Mbit/s "floor"
        catchingUp = false
        Task {
            do {
                try await engine.start(cfg)
            } catch {
                phase = .idle
                let ns = error as NSError
                if ns.domain == SCStreamErrorDomain || ns.code == -3801 {
                    CGRequestScreenCaptureAccess()
                    permissionProblem = true
                    status = Loc("No screen recording access", "Нет доступа к записи экрана")
                } else {
                    status = Loc("Could not start: \(error.localizedDescription)", "Не удалось начать: \(error.localizedDescription)")
                }
                log("start: \(error)")
                return
            }
            phase = .streaming
            loadDisplays()
            if extendMode {
                hint = Loc("The \"TVMirror\" second display is attached to the right of the main one — drag windows onto it. " +
                               "You can change the arrangement in System Settings → Displays.",
                           "Второй экран «TVMirror» подключён справа от основного — перетащите на него окна. " +
                               "Расположение меняется в Системных настройках → Мониторы.")
            }
            let me = localIP(toward: tv.ip) ?? "?"
            // only this TV may connect, at a path that is new for every session
            let path = server.authorize(host: tv.ip)
            status = Loc("Sending the stream to the TV (DLNA)…", "Отправляю поток на телевизор (DLNA)…")
            do {
                try await DLNA.play(tv, url: "http://\(me):\(server.port)\(path)")
                if !tvConnected { status = Loc("Waiting for the TV player to connect…", "Жду, пока плеер телевизора подключится…") }
                let mon = DLNALatency(tv: tv, engine: engine, server: server, catchUp: reduceLatency)
                mon.start()
                monitor = mon
            } catch {
                stop()
                status = Loc("The TV did not accept the stream: \(error.localizedDescription)",
                             "Телевизор не принял поток: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard phase != .idle else { return }
        monitor?.stop(); monitor = nil
        engine.stop()
        phase = .idle
        latency = nil
        tvConnected = false
        hint = nil
        status = Loc("Streaming stopped", "Трансляция остановлена")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.loadDisplays() }
        if let tv = activeTV { Task { await DLNA.stop(tv) } }
    }

    func shutdown() {
        monitor?.stop(); monitor = nil
        engine.stop()
        guard let tv = activeTV else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await DLNA.stop(tv); sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }

    private func engineStopped(_ reason: String) {
        monitor?.stop(); monitor = nil
        phase = .idle
        latency = nil
        tvConnected = false
        status = Loc("Streaming was interrupted: \(reason)", "Трансляция прервалась: \(reason)")
    }

    private func serverEvent(_ kind: String, _ remote: String) {
        guard phase != .idle else { return }
        switch kind {
        case "ts-open":
            tvConnected = true
            status = Loc("The TV connected and is starting its player…", "Телевизор подключился, запускает плеер…")
        case "ts-close" where server.tsCount == 0:
            tvConnected = false
            status = Loc("The TV player disconnected from the stream", "Плеер телевизора отключился от потока")
        default:
            break
        }
    }

    /// Assign @Published only on a real change: every assignment re-renders the whole window.
    private func update<T: Equatable>(_ kp: ReferenceWritableKeyPath<AppModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    /// Once a second. Latency used to be published ~10 times a second straight from the measurement, and SwiftUI
    /// kept recomputing the window layout together with the log — that ate ~90% of the CPU.
    private func tick() {
        guard phase == .streaming, engine.running else { update(\.statsLine, ""); return }
        update(\.statsLine, String(format: tr("%d×%d · %.0f fps · %.1f Mbit/s", "%d×%d · %.0f кадр/с · %.1f Мбит/с"),
                                   engine.width, engine.height, engine.fpsOut.rounded(), (engine.kbpsOut / 100).rounded() / 10))
        update(\.catchingUp, engine.playbackRate < 1)
        update(\.latency, monitor?.latency.map { ($0 * 100).rounded() / 100 })
        if tvConnected, latency != nil {
            update(\.status, catchingUp ? Loc("Streaming — reducing latency (audio returns in a few seconds)",
                                              "Идёт трансляция — сокращаю задержку (звук вернётся через несколько секунд)")
                                        : .streaming)
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openLocalNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }

    func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - window

struct ContentView: View {
    @ObservedObject var m: AppModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    // the label stays bilingual so it can be found in either language
                    Picker("Language / Язык", selection: $m.language) {
                        ForEach(UILanguage.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section(tr("TV", "Телевизор")) { tvSection }
                Section(tr("What to show on the TV", "Что показывать на телевизоре")) {
                    Picker(tr("What to show", "Что показывать"), selection: $m.extend) {
                        Text(tr("Mirror Mac screen", "Повтор экрана Mac")).tag(false)
                        Text(tr("Second display", "Второй экран")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(m.extend
                         ? tr("TVMirror will create an extra 1920×1080 monitor — the Mac will see the TV as a second display. Drag windows and videos onto it. When you stop, the monitor disappears and windows move back to the Mac screen.",
                              "TVMirror создаст дополнительный монитор 1920×1080 — Mac увидит телевизор как второй экран. Перетаскивайте на него окна и видео. После остановки монитор исчезнет, окна вернутся на экран Mac.")
                         : tr("The TV shows the same as the Mac screen.", "Телевизор показывает то же, что экран Mac."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(m.phase != .idle)
                Section(tr("Latency", "Задержка")) {
                    Toggle(tr("Reduce latency to ~1 second", "Сокращать задержку до ~1 секунды"), isOn: $m.reduceLatency)
                    Text(m.reduceLatency
                         ? tr("The TV player builds up ~5 s of headroom on its own. After the start, TVMirror shows the picture slightly faster and without sound for about 12 seconds — the headroom melts away and latency drops to ~1 s. The stream is also padded with empty data up to 8 Mbit/s.",
                              "Плеер телевизора сам копит ~5 с запаса. После старта TVMirror примерно 12 секунд показывает картинку чуть быстрее и без звука — запас тает, и задержка падает до ~1 с. Поток при этом дополняется пустыми данными до 8 Мбит/с.")
                         : tr("Latency about 5 seconds — that's how much headroom the TV player buffers.",
                              "Задержка около 5 секунд — столько запаса копит плеер телевизора."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(m.phase != .idle)
                Section(tr("Picture and sound", "Картинка и звук")) {
                    if m.displays.count > 1 && !m.extend {
                        Picker(tr("Display", "Экран"), selection: $m.displayID) {
                            ForEach(m.displays) { Text($0.name).tag($0.id) }
                        }
                    }
                    Picker(tr("Quality", "Качество"), selection: $m.height) {
                        Text("720p").tag(720)
                        Text("1080p").tag(1080)
                    }
                    .pickerStyle(.segmented)
                    Toggle(tr("60 fps — smoother, but more load", "60 кадров/с — плавнее, но больше нагрузка"), isOn: $m.fps60)
                    Toggle(tr("Send Mac audio to the TV", "Передавать звук Mac на телевизор"), isOn: $m.audio)
                }
                .disabled(m.phase != .idle)
                Section {
                    DisclosureGroup(tr("Log", "Журнал"), isExpanded: $showLog) {
                        LogView()
                        Text(tr("TV and computer names, your home folder and network addresses are masked in the log, so it is safe to attach to a bug report.",
                                "Названия ТВ и компьютера, домашняя папка и сетевые адреса в журнале скрыты — его можно приложить к сообщению об ошибке."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(tr("Copy log", "Скопировать журнал")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Log.shared.lines.joined(separator: "\n"), forType: .string)
                            }
                            Button(tr("Show file", "Показать файл")) { NSWorkspace.shared.activateFileViewerSelecting([Log.shared.fileURL]) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            statusPanel.padding(16)
        }
        .frame(width: 500)
        .frame(minHeight: 720)
    }

    @ViewBuilder private var tvSection: some View {
        if m.tvs.isEmpty {
            HStack(spacing: 8) {
                if m.discovering { ProgressView().controlSize(.small) }
                Text(m.discovering ? tr("Searching for TVs on the network…", "Ищу телевизоры в сети…")
                                   : tr("No TV found yet", "Телевизор пока не найден"))
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker(tr("TV", "Телевизор"), selection: $m.selectedTV) {
                ForEach(m.tvs) { tv in
                    Text("\(tv.label)   \(tv.ip)").tag(Optional(tv.id))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        HStack {
            Button { m.discover() } label: { Label(tr("Search again", "Найти снова"), systemImage: "arrow.clockwise") }
                .disabled(m.discovering)
            if m.discovering && !m.tvs.isEmpty { ProgressView().controlSize(.small) }
            Spacer()
            TextField(tr("Manual IP", "IP вручную"), text: $m.manualIP, prompt: Text(tr("Manual IP", "IP вручную")))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onSubmit { m.addManual() }
            Button(tr("Add", "Добавить")) { m.addManual() }
                .disabled(m.manualIP.isEmpty)
        }
        .disabled(m.phase != .idle)
    }

    private var dotColor: Color {
        switch m.phase {
        case .idle: return m.permissionProblem ? .orange : .secondary
        case .starting: return .yellow
        case .streaming: return m.tvConnected ? .green : .yellow
        }
    }

    private func latencyColor(_ l: Double) -> Color { l < 1.4 ? .green : (l < 2.5 ? .orange : .red) }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(dotColor).frame(width: 9, height: 9)
                Text(m.status.text).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let l = m.latency {
                    Text(String(format: tr("latency %.2f s", "задержка %.2f с"), l))
                        .font(.system(.body, design: .rounded)).monospacedDigit()
                        .foregroundStyle(latencyColor(l))
                }
            }
            if !m.statsLine.isEmpty {
                Text(m.statsLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let hint = m.hint {
                Text(hint.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if m.networkBlocked {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("macOS doesn't let TVMirror onto the home network. Allow it in System Settings → Privacy & Security → Local Network → TVMirror. The search repeats by itself when you come back to the app.",
                            "macOS не пускает TVMirror в домашнюю сеть. Разрешите: Системные настройки → Конфиденциальность и безопасность → Локальная сеть → TVMirror. Поиск повторится сам, когда вы вернётесь в приложение."))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(tr("Open Settings", "Открыть настройки")) { m.openLocalNetworkSettings() }
                        Button(tr("Search again", "Найти снова")) { m.discover() }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if m.permissionProblem {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Allow TVMirror to record the screen and audio: System Settings → Privacy & Security → Screen & System Audio Recording. If TVMirror is already on there but doesn't work, remove it from the list with the \"−\" button and allow it again. Then restart the app.",
                            "Разрешите TVMirror запись экрана и звука: Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного аудио. Если TVMirror там уже включён, но не работает — удалите его из списка кнопкой «−» и разрешите заново. Затем перезапустите приложение."))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(tr("Open Settings", "Открыть настройки")) { m.openPrivacySettings() }
                        Button(tr("Restart TVMirror", "Перезапустить TVMirror")) { m.relaunch() }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Spacer()
                Button {
                    if m.phase == .idle { m.start() } else { m.stop() }
                } label: {
                    Text(m.phase == .idle ? tr("Start streaming", "Начать трансляцию")
                                          : (m.phase == .starting ? tr("Starting…", "Запускаю…") : tr("Stop", "Остановить")))
                        .frame(minWidth: 170)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(m.phase == .idle ? .accentColor : .red)
                .disabled(m.phase == .starting || (m.phase == .idle && m.selected == nil))
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct TVMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var model = AppModel.shared

    var body: some Scene {
        Window("TVMirror", id: "main") {
            ContentView(m: model)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

/// The in-window log lives separately from AppModel: its updates don't re-render the rest of the window.
/// The text is assembled only while the log is expanded, and at most once a second.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()
    @Published private(set) var text = ""
    private var visible = false
    private var pending = false

    func setVisible(_ v: Bool) {
        visible = v
        if v { refresh() }
    }

    func lineAdded() {
        guard visible, !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.pending = false
            self?.refresh()
        }
    }

    private func refresh() {
        let t = Log.shared.lines.suffix(150).joined(separator: "\n")
        if t != text { text = t }
    }
}

struct LogView: View {
    @ObservedObject private var store = LogStore.shared

    var body: some View {
        ScrollView {
            Text(store.text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 160)
        .onAppear { store.setVisible(true) }
        .onDisappear { store.setVisible(false) }
    }
}
