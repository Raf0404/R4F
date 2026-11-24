import AppKit
import CoreAudio
import ServiceManagement

/// LiveBus.app: icona nella barra dei menu, niente finestre né Dock.
/// Avvia il router all'apertura, lo riavvia quando cambia la config o una scheda,
/// risponde agli URL livebus://start|stop|restart (usati dal device in Live).
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let supportDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/R4F")
    static let defaultConfig = (supportDir as NSString).appendingPathComponent("config.json")
    static let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/R4F.log")
    private static let configKey = "configPath"

    private let controller: RouterController
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var editor: ConfigEditorWindow?
    private var boxStatus = ""
    private var boxListener: AudioObjectPropertyListenerBlock?

    override init() {
        let saved = UserDefaults.standard.string(forKey: MenuBarApp.configKey)
        let path = saved.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? MenuBarApp.defaultConfig
        controller = RouterController(configPath: path)
        super.init()
    }

    // MARK: ciclo di vita

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        controller.onChange = { [weak self] in self?.refreshIcon() }

        migrateFromLiveBus()
        ensureConfig()
        controller.watchConfig()
        controller.watchDevices()
        controller.start()
        boxStatus = R4FBox.syncFromFile()
        print(boxStatus)
        watchBoxDevice()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.controller.tick()
            self?.refreshIcon()
        }
        refreshIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        switch url.host ?? "" {
        case "stop": controller.stop()
        case "restart": controller.restart()
        default: if !controller.isRunning { controller.start() }  // "start" e qualsiasi altro
        }
    }

    // MARK: configurazione

    private func ensureConfig() {
        let path = controller.configPath
        guard !FileManager.default.fileExists(atPath: path) else { return }
        do {
            let cfg = try DefaultConfig.make(devices: CoreAudioHelpers.allDevices())
            try DefaultConfig.write(cfg, to: path)
            print("creata la configurazione iniziale: \(path)")
        } catch {
            print("impossibile creare la configurazione iniziale: \(error)")
        }
    }

    // MARK: icona

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        var tip = "R4F"
        switch controller.state {
        case .running:
            let xr = controller.router?.hasXruns ?? false
            let clip = controller.router?.hasClip ?? false
            let loop = controller.router?.loopWarning != nil
            symbol = (xr || clip || loop) ? "exclamationmark.circle" : "hifispeaker.2.fill"
            tip += clip ? " — CLIP su un'uscita" : xr ? " — in esecuzione, con xrun" : " — in esecuzione"
        case .stopped:
            symbol = "hifispeaker.2"
            tip += " — fermo"
        case .failed(let m):
            symbol = "exclamationmark.triangle"
            tip += " — errore: " + m
        }
        if button.image?.accessibilityDescription != symbol {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            img?.isTemplate = true
            button.image = img
        }
        button.appearsDisabled = { if case .stopped = controller.state { return true }; return false }()
        button.toolTip = tip
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch controller.state {
        case .running:
            let r = controller.router!
            info("R4F BUS in esecuzione")
            info("bus: \(r.bus.name) (\(r.bus.inputChannels) canali)")
            for line in r.outputLines() { info("  " + line) }
            if let w = r.loopWarning { for part in wrap("⚠︎ " + w, 70) { info(part) } }
            let n = r.deviceCount
            if n > 0 { info("device R4F Out (Ableton Live) collegati: \(n)") }
        case .stopped:
            info("R4F BUS fermo")
        case .failed(let m):
            info("Errore — nuovo tentativo ogni 5 s")
            for part in wrap(m, 70) { info("  " + part) }
        }
        info(boxStatus.isEmpty ? "R4F BOX" : boxStatus)
        menu.addItem(.separator())
        if controller.isRunning {
            item("Ferma", #selector(stopRouter))
            item("Riavvia", #selector(restartRouter))
        } else {
            item("Avvia", #selector(startRouter))
        }
        menu.addItem(.separator())
        info("config: " + (controller.configPath as NSString).abbreviatingWithTildeInPath)
        item("Configura R4F BUS…", #selector(openEditor), key: ",")
        item("Configura R4F BOX…", #selector(openBoxEditor))
        item("Nuova configurazione BUS…", #selector(newConfig))
        item("Scegli configurazione…", #selector(chooseConfig))
        item("Apri il file JSON", #selector(editConfig))
        if controller.configPath != MenuBarApp.defaultConfig {
            item("Usa la configurazione predefinita", #selector(useDefaultConfig))
        }
        let devItem = NSMenuItem(title: "Dispositivi audio (clic = copia il nome)", action: nil, keyEquivalent: "")
        devItem.submenu = devicesMenu()
        menu.addItem(devItem)
        item("Mostra il log", #selector(showLog))
        menu.addItem(.separator())
        let login = item("Avvia all'accesso", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item("Esci da R4F", #selector(quit), key: "q")
    }

    private func info(_ title: String) {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        menu.addItem(it)
    }

    @discardableResult
    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
        return it
    }

    private func devicesMenu() -> NSMenu {
        let m = NSMenu()
        for d in CoreAudioHelpers.allDevices() {
            var kind = d.isVirtual ? "virtuale" : d.isAggregate ? "aggregato" : d.isBuiltIn ? "integrato" : "scheda"
            kind += ", in \(d.inputChannels) / out \(d.outputChannels)"
            let it = NSMenuItem(title: "\(d.name)  (\(kind))", action: #selector(copyName(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.name
            m.addItem(it)
        }
        return m
    }

    private func wrap(_ s: String, _ width: Int) -> [String] {
        var lines: [String] = [], cur = ""
        for w in s.split(separator: " ") {
            if cur.count + w.count + 1 > width, !cur.isEmpty { lines.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + w
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    // MARK: azioni

    @objc private func startRouter() { controller.start() }
    @objc private func stopRouter() { controller.stop() }
    @objc private func restartRouter() { controller.restart() }

    @objc private func editConfig() {
        ensureConfig()
        NSWorkspace.shared.open(URL(fileURLWithPath: controller.configPath))
    }

    // MARK: editor grafico

    @objc private func openEditor() {
        ensureConfig()
        showEditor(.bus) { m in try m.loadFile(self.controller.configPath) }
    }

    @objc private func openBoxEditor() {
        ensureConfig()
        showEditor(.box) { m in try m.loadFile(self.controller.configPath) }
    }

    @objc private func newConfig() {
        showEditor(.bus) { m in try m.loadDefaults() }
    }

    private func showEditor(_ kind: EditorKind, _ prepare: (ConfigEditorModel) throws -> Void) {
        if let e = editor {
            // finestra già aperta: se BUS non ha modifiche si ricarica con il contenuto richiesto
            if kind == .bus && !e.model.isDirty { try? prepare(e.model) }
            e.show(kind)
            return
        }
        let m = ConfigEditorModel()
        do { try prepare(m) } catch {
            // config illeggibile: si parte dai dispositivi, con il percorso attuale come destinazione
            try? m.loadDefaults()
            m.path = controller.configPath
            print("editor: \(error)")
        }
        let bm = ConfigEditorModel()
        bm.loadBox(R4FBox.load(), device: R4FBox.device())
        let e = ConfigEditorWindow(model: m, boxModel: bm)
        e.onBoxSaved = { [weak self] msg in self?.boxStatus = msg; print(msg) }
        e.onSaved = { [weak self] path in
            guard let self = self else { return }
            if path != self.controller.configPath {
                self.setConfig(path)
            } else {
                self.controller.watchConfig()
                self.controller.restartSoon("configurazione salvata dall'editor", delay: 0.3)
            }
        }
        e.onClose = { [weak self] in self?.editor = nil }
        editor = e
        e.show(kind)
    }

    // MARK: R4F BOX e migrazione

    /// Se R4F BOX viene installato o reinstallato, il driver riceve di nuovo la matrice salvata.
    private func watchBoxDevice() {
        var addr = CoreAudioHelpers.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // R4F BUS appena installato: il vecchio bus LiveBus nella config viene sostituito
                // (il file cambia e il router si riavvia da solo)
                self?.migrateFromLiveBus()
                self?.boxStatus = R4FBox.syncFromFile()
                print(self?.boxStatus ?? "")
            }
        }
        boxListener = block
        AudioObjectAddPropertyListenerBlock(CoreAudioHelpers.system, &addr, DispatchQueue.main, block)
    }

    /// Da LiveBus a R4F: copia la configurazione nella nuova cartella e, se R4F BUS è installato,
    /// sostituisce il vecchio bus "LiveBus…" (con una copia di sicurezza).
    private func migrateFromLiveBus() {
        let fm = FileManager.default
        let oldDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/LiveBus")
        let oldCfg = (oldDir as NSString).appendingPathComponent("config.json")
        if !fm.fileExists(atPath: MenuBarApp.defaultConfig), fm.fileExists(atPath: oldCfg) {
            try? fm.createDirectory(atPath: MenuBarApp.supportDir, withIntermediateDirectories: true)
            if (try? fm.copyItem(atPath: oldCfg, toPath: MenuBarApp.defaultConfig)) != nil {
                print("configurazione copiata da \(oldCfg)")
            }
        }
        let path = controller.configPath
        guard var cfg = try? LiveBusConfig.load(path), cfg.bus.hasPrefix("LiveBus") else { return }
        let devices = CoreAudioHelpers.allDevices()
        guard let r4f = devices.first(where: { $0.name == "R4F BUS" && $0.inputChannels > 0 }) else { return }
        let backup = path + ".backup-livebus"
        try? fm.removeItem(atPath: backup)
        try? fm.copyItem(atPath: path, toPath: backup)
        let old = cfg.bus
        cfg.bus = r4f.name
        do {
            try DefaultConfig.write(cfg, to: path)
            print("bus aggiornato: \(old) → \(r4f.name) (copia: \(backup))")
        } catch {
            print("migrazione del bus non riuscita: \(error)")
        }
    }

    @objc private func chooseConfig() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.directoryURL = URL(fileURLWithPath: (controller.configPath as NSString).deletingLastPathComponent)
        p.message = "Scegli la configurazione di R4F BUS"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        setConfig(url.path)
    }

    @objc private func useDefaultConfig() {
        ensureConfig()
        setConfig(MenuBarApp.defaultConfig)
    }

    private func setConfig(_ path: String) {
        UserDefaults.standard.set(path, forKey: MenuBarApp.configKey)
        controller.configPath = path
        controller.start()
    }

    @objc private func copyName(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: MenuBarApp.logPath))
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Avvio all'accesso non riuscito"
            a.informativeText = "\(error.localizedDescription)\n\nIn alternativa aggiungi R4F in Impostazioni di Sistema → Generali → Elementi login."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Modalità app: log su file, nessuna finestra.
func runMenuBarApp() -> Never {
    try? FileManager.default.createDirectory(atPath: MenuBarApp.supportDir, withIntermediateDirectories: true)
    if isatty(STDOUT_FILENO) == 0 {
        freopen(MenuBarApp.logPath, "a", stdout)
        freopen(MenuBarApp.logPath, "a", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)
    }
    print("\n— R4F avviato \(Date())")
    let app = NSApplication.shared
    let delegate = MenuBarApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
    exit(0)
}
