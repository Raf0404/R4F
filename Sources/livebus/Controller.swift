import CoreAudio
import Foundation

/// Ciclo di vita del router per l'app: avvio, arresto, nuovi tentativi,
/// riavvio quando cambia la configurazione o l'elenco dei dispositivi.
final class RouterController {
    enum State {
        case stopped
        case running
        case failed(String)
    }

    private(set) var state: State = .stopped
    private(set) var router: Router?
    private var osc: OSCServer?
    private var retryWork: DispatchWorkItem?
    private var debounceWork: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var rateListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var wantRunning = false
    var configPath: String { didSet { watchConfig() } }
    var onChange: (() -> Void)?

    init(configPath: String) {
        self.configPath = configPath
    }

    var isRunning: Bool { if case .running = state { return true }; return false }

    func start() {
        wantRunning = true
        teardown()
        do {
            let cfg = try LiveBusConfig.load(configPath)
            let r = try Router(config: cfg)
            let port = cfg.oscPort ?? 7400
            let o: OSCServer? = port > 0 ? try OSCServer(port: UInt16(port)) { [weak r] m in r?.handle(m) } : nil
            try r.start()
            o?.start()
            router = r
            osc = o
            state = .running
            watchRates(r)
            log("avviato con \(configPath)\n" + r.summary())
        } catch {
            state = .failed("\(error)")
            log("errore: \(error)")
            scheduleRetry()
        }
        onChange?()
    }

    func stop() {
        wantRunning = false
        retryWork?.cancel()
        teardown()
        state = .stopped
        log("fermato")
        onChange?()
    }

    func restart() { start() }

    /// Ogni secondo dal timer dell'app.
    func tick() { router?.tick() }

    private func teardown() {
        unwatchRates()
        router?.stop()
        router = nil
        osc?.stop()
        osc = nil
    }

    // Un dispositivo mancante (scheda non ancora collegata) non è definitivo: si riprova.
    private func scheduleRetry() {
        retryWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.wantRunning, !self.isRunning else { return }
            self.start()
        }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    func restartSoon(_ why: String, delay: Double) {
        debounceWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.wantRunning else { return }
            self.log("riavvio: \(why)")
            self.start()
        }
        debounceWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // MARK: osservatori

    func watchConfig() {
        watcher?.cancel()
        watcher = nil
        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            // gli editor salvano spesso sostituendo il file: si riaggancia l'osservatore
            if src.data.contains(.rename) || src.data.contains(.delete) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.watchConfig() }
            }
            self.restartSoon("configurazione modificata", delay: 0.6)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    // Le DAW cambiano spesso la frequenza del dispositivo (Logic, Reaper, Pro Tools seguono il progetto):
    // il ricampionatore è configurato all'avvio, quindi si riavvia.
    private func watchRates(_ r: Router) {
        var ids = [r.bus.id] + r.outputs.map { $0.device.id }
        ids = Array(Set(ids))
        for id in ids {
            var addr = CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.restartSoon("frequenza di campionamento cambiata", delay: 0.8)
            }
            if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
                rateListeners.append((id, block))
            }
        }
    }

    private func unwatchRates() {
        for (id, block) in rateListeners {
            var addr = CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, block)
        }
        rateListeners = []
    }

    func watchDevices() {
        var addr = CoreAudioHelpers.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.restartSoon("dispositivi audio cambiati", delay: 1.5)
        }
        devicesListener = block
        AudioObjectAddPropertyListenerBlock(CoreAudioHelpers.system, &addr, DispatchQueue.main, block)
    }

    private func log(_ s: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(ts)] \(s)")
    }
}
