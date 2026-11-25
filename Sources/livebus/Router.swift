import CLiveBus
import CoreAudio
import Foundation

/// Collega il motore C ai dispositivi CoreAudio e gestisce le rotte, raggruppate per proprietario.
final class Router {
    struct Output {
        let id: String
        let device: AudioDevice
        let target: Int
        let latencyMs: Double
        var procID: AudioDeviceIOProcID?
    }

    static let ownerTTL: TimeInterval = 6

    let bus: AudioDevice
    private(set) var outputs: [Output]
    private let engine: OpaquePointer
    private var inputProc: AudioDeviceIOProcID?
    private let book = RouteBook()
    private let lock = NSLock()
    private let session = Date().timeIntervalSince1970
    let statusPath: String?

    // statistiche aggiornate da tick() una volta al secondo
    private var busPeaks: [Float]
    private var lastStats: [lb_output_stats]
    /// ultimo istante in cui un'uscita ha superato 0 dBFS (l'avviso resta acceso 5 s)
    private var lastClip: [TimeInterval]
    private func clipping(_ i: Int) -> Bool { now() - lastClip[i] < 5 }

    var outputInfo: [OutputInfo] { outputs.map { OutputInfo(id: $0.id, channels: $0.device.outputChannels) } }

    init(config: LiveBusConfig) throws {
        let devices = CoreAudioHelpers.allDevices()
        var busDev = try CoreAudioHelpers.find(config.bus, in: devices, direction: .input)
        if let bf = config.bufferFrames {
            CoreAudioHelpers.setBufferFrames(busDev.id, bf)
            busDev = CoreAudioHelpers.device(busDev.id)
        }

        guard !config.outputs.isEmpty else { throw LBError("no outputs in the configuration") }
        var resolved: [(OutputSpec, AudioDevice)] = []
        var seenIds = Set<String>(), seenDevs = Set<AudioObjectID>()
        for spec in config.outputs {
            guard !spec.id.isEmpty, !spec.id.contains(":"), !spec.id.contains("@"), !spec.id.contains(" ") else {
                throw LBError("invalid output id: '\(spec.id)' (no spaces, ':' or '@')")
            }
            guard seenIds.insert(spec.id).inserted else { throw LBError("duplicate output id: \(spec.id)") }
            var dev = try CoreAudioHelpers.find(spec.device, in: devices, direction: .output)
            guard seenDevs.insert(dev.id).inserted else { throw LBError("the device '\(dev.name)' is used by two outputs") }
            if let bf = config.bufferFrames {
                CoreAudioHelpers.setBufferFrames(dev.id, bf)
                dev = CoreAudioHelpers.device(dev.id)
            }
            resolved.append((spec, dev))
        }

        // Riempimento obiettivo di ogni ring: buffer del bus + buffer dell'uscita + filtro + margine.
        let safety = max(0, config.safetyFrames ?? 128)
        let taps = Int(LB_TAPS)
        let busRate = busDev.sampleRate
        var targets = resolved.map { busDev.bufferFrames + $0.1.bufferFrames + taps + safety }
        func latency(_ i: Int) -> Double {
            let d = resolved[i].1
            return Double(targets[i]) / busRate + Double(d.bufferFrames + d.outputLatency) / d.sampleRate
        }
        if config.alignOutputs ?? true, resolved.count > 1 {
            let maxLat = resolved.indices.map(latency).max() ?? 0
            for i in resolved.indices { targets[i] += Int(((maxLat - latency(i)) * busRate).rounded()) }
        }
        for i in resolved.indices {
            targets[i] += Int(((resolved[i].0.delayMs ?? 0) / 1000 * busRate).rounded())
        }

        let maxTarget = targets.max() ?? 0
        var ring = 16384
        while ring < maxTarget * 4 { ring *= 2 }
        let chans = resolved.map { UInt32($0.1.outputChannels) }
        guard let eng = lb_engine_create(UInt32(busDev.inputChannels), busRate, AudioGetHostClockFrequency(),
                                         UInt32(resolved.count), chans, 8192, UInt32(ring)) else {
            throw LBError("could not create the engine (bus channels: \(busDev.inputChannels))")
        }

        let ff = config.feedForward ?? true
        var outs: [Output] = []
        for (i, (spec, dev)) in resolved.enumerated() {
            lb_engine_config_output(eng, UInt32(i), busRate / dev.sampleRate, UInt32(targets[i]), ff ? 1 : 0, dev.sampleRate)
            outs.append(Output(id: spec.id, device: dev, target: targets[i], latencyMs: latency(i) * 1000, procID: nil))
        }

        bus = busDev
        outputs = outs
        engine = eng
        busPeaks = [Float](repeating: 0, count: busDev.inputChannels)
        lastStats = [lb_output_stats](repeating: lb_output_stats(), count: outs.count)
        lastClip = [TimeInterval](repeating: 0, count: outs.count)
        let sp = config.statusFile ?? "/tmp/livebus-status.json"
        statusPath = sp.isEmpty ? nil : (sp as NSString).expandingTildeInPath

        if let specs = config.routes {
            let r = try expandConfig(specs)
            lock.lock(); book.set("config", routes: r, now: now(), expires: false); applyLocked(); lock.unlock()
        }
    }

    deinit {
        stop()
        lb_engine_destroy(engine)
    }

    private func now() -> TimeInterval { Date().timeIntervalSince1970 }

    // MARK: avvio

    func start() throws {
        for i in outputs.indices {
            var pid: AudioDeviceIOProcID?
            try check(lb_create_output_proc(engine, UInt32(i), outputs[i].device.id, &pid), "output IOProc \(outputs[i].id)")
            outputs[i].procID = pid
            try check(AudioDeviceStart(outputs[i].device.id, pid), "starting output \(outputs[i].id)")
        }
        var pid: AudioDeviceIOProcID?
        try check(lb_create_input_proc(engine, bus.id, &pid), "bus IOProc")
        inputProc = pid
        try check(AudioDeviceStart(bus.id, pid), "starting bus")
    }

    func stop() {
        if let p = inputProc {
            AudioDeviceStop(bus.id, p)
            AudioDeviceDestroyIOProcID(bus.id, p)
            inputProc = nil
        }
        for i in outputs.indices {
            if let p = outputs[i].procID {
                AudioDeviceStop(outputs[i].device.id, p)
                AudioDeviceDestroyIOProcID(outputs[i].device.id, p)
                outputs[i].procID = nil
            }
        }
        if let p = statusPath { try? FileManager.default.removeItem(atPath: p) }
    }

    // MARK: rotte

    func expandConfig(_ specs: [RouteSpec]) throws -> [RouteKey: Float] {
        var result: [RouteKey: Float] = [:]
        for r in specs {
            let part = try RouteSpecParser.expand(src: r.from.channels, dest: r.to, busChannels: bus.inputChannels,
                                                  outputs: outputInfo, gainDb: r.gainDb ?? 0, sum: r.isSum)
            result.merge(part) { _, new in new }
        }
        return result
    }

    /// Avviso attivo se alcune rotte sono state scartate perché creavano un anello nel bus.
    private(set) var loopWarning: String?

    private func applyLocked() {
        var merged = book.merged()
        let busOuts = Set(outputs.indices.filter { outputs[$0].device.id == bus.id })
        let bad = LoopGuard.loopingKeys(merged, busOutputs: busOuts)
        if bad.isEmpty {
            if loopWarning != nil { print("bus loop resolved") }
            loopWarning = nil
        } else {
            for k in bad { merged[k] = nil }
            let list = bad.sorted { ($0.src, $0.dst) < ($1.src, $1.dst) }.prefix(4)
                .map { "bus \($0.src + 1) → \(outputs[$0.out].id):\($0.dst + 1)" }.joined(separator: ", ")
            let w = "routes dropped because they send the signal back into the bus it comes from (loop): \(list)"
            if w != loopWarning { print("WARNING: " + w) }
            loopWarning = w
        }
        var arr = merged.map {
            lb_route(src: UInt32($0.key.src), out: UInt32($0.key.out), dst: UInt32($0.key.dst), gain: $0.value)
        }
        _ = lb_engine_set_routes(engine, &arr, UInt32(arr.count))
    }

    /// Rotta manuale (OSC route/unroute). Canali 1-based. gain 0 = rimuovi.
    func setRoute(src: Int, out: Int, dst: Int, gain: Float) throws {
        guard src >= 1, src <= bus.inputChannels else { throw LBError("bus channel \(src) out of range 1-\(bus.inputChannels)") }
        guard out >= 0, out < outputs.count else { throw LBError("output \(out) does not exist") }
        guard dst >= 1, dst <= outputs[out].device.outputChannels else {
            throw LBError("channel \(dst) out of range for \(outputs[out].id) (1-\(outputs[out].device.outputChannels))")
        }
        lock.lock(); defer { lock.unlock() }
        let changed = book.edit("manual", now: now()) { $0[RouteKey(src: src - 1, out: out, dst: dst - 1)] = gain > 0 ? gain : nil }
        if changed { applyLocked() }
    }

    func replaceConfigRoutes(_ r: [RouteKey: Float]) {
        lock.lock(); defer { lock.unlock() }
        book.remove("manual")
        book.set("config", routes: r, now: now(), expires: false)
        applyLocked()
    }

    /// Rotte di un device R4F Out: sostituisce quelle precedenti dello stesso proprietario.
    /// Ritorna nil se tutto ok, altrimenti il messaggio d'errore (salvato anche nello stato).
    @discardableResult
    func setOwner(_ owner: String, src: String, dest: String, gainDb: Double) -> String? {
        let t = now()
        do {
            let srcList = src.trimmingCharacters(in: .whitespaces).isEmpty ? [] : try ChannelList.parse(src)
            let r = srcList.isEmpty ? [:] : try RouteSpecParser.expand(src: srcList, dest: dest, busChannels: bus.inputChannels,
                                                                         outputs: outputInfo, gainDb: gainDb)
            lock.lock(); defer { lock.unlock() }
            let isNew = book.owners[owner] == nil || book.owners[owner]?.dest != dest || book.owners[owner]?.src != src
            if book.set(owner, routes: r, src: src, dest: dest, now: t, expires: true) { applyLocked() }
            if isNew { print("device \(owner): bus \(src.isEmpty ? "-" : src) → \(dest.isEmpty ? "-" : dest) (\(r.count) routes)") }
            return nil
        } catch {
            let msg = "\(error)"
            lock.lock(); defer { lock.unlock() }
            let old = book.owners[owner]
            if book.set(owner, routes: [:], src: src, dest: dest, now: t, expires: true, error: msg) { applyLocked() }
            if old?.error != msg { print("device \(owner): error — \(msg)") }
            return msg
        }
    }

    func releaseOwner(_ owner: String) {
        lock.lock(); defer { lock.unlock() }
        let existed = book.owners[owner] != nil
        if book.remove(owner) { applyLocked() }
        if existed { print("device \(owner): released") }
    }

    func outputIndex(_ id: String) -> Int? {
        if let i = outputs.firstIndex(where: { $0.id == id }) { return i }
        if let n = Int(id), n >= 1, n <= outputs.count { return n - 1 }
        return nil
    }

    func routeList() -> [String] {
        lock.lock(); let m = book.merged(); lock.unlock()
        return m.keys.sorted { ($0.out, $0.dst, $0.src) < ($1.out, $1.dst, $1.src) }.map {
            "  bus \($0.src + 1) → \(outputs[$0.out].id):\($0.dst + 1)  \(linToDbString(m[$0]!)) dB"
        }
    }

    // MARK: OSC

    func handle(_ m: OSCMessage) {
        do {
            switch m.address {
            case "/livebus/set":
                // <owner> <canali bus> <destinations> [dB]
                guard m.args.count >= 2, let owner = m.args[0].stringValue, !owner.isEmpty else {
                    throw LBError("usage: /livebus/set <owner> <bus> <destinations> [dB]")
                }
                let src = m.args[1].stringValue ?? ""
                let dest = m.args.count >= 3 ? (m.args[2].stringValue ?? "") : ""
                let db = m.args.count >= 4 ? (m.args[3].doubleValue ?? 0) : 0
                setOwner(owner, src: src, dest: dest, gainDb: db)
            case "/livebus/release":
                guard let owner = m.args.first?.stringValue else { throw LBError("usage: /livebus/release <owner>") }
                releaseOwner(owner)
            case "/livebus/route", "/livebus/gain":
                guard m.args.count >= 3, let s = m.args[0].intValue, let o = m.args[1].stringValue,
                      let oi = outputIndex(o), let d = m.args[2].intValue else {
                    throw LBError("usage: \(m.address) <bus> <output> <channel> [dB]")
                }
                let db = m.args.count >= 4 ? (m.args[3].doubleValue ?? 0) : 0
                try setRoute(src: s, out: oi, dst: d, gain: dbToLin(db))
                print("OSC route bus \(s) → \(outputs[oi].id):\(d) \(String(format: "%.1f", db)) dB")
            case "/livebus/unroute":
                guard m.args.count >= 3, let s = m.args[0].intValue, let o = m.args[1].stringValue,
                      let oi = outputIndex(o), let d = m.args[2].intValue else {
                    throw LBError("usage: /livebus/unroute <bus> <output> <channel>")
                }
                try setRoute(src: s, out: oi, dst: d, gain: 0)
                print("OSC removed bus \(s) → \(outputs[oi].id):\(d)")
            case "/livebus/clear":
                replaceConfigRoutes([:])
                print("OSC config and manual routes cleared (R4F Out devices stay)")
            case "/livebus/load":
                guard let path = m.args.first?.stringValue else { throw LBError("usage: /livebus/load <file.json>") }
                let cfg = try LiveBusConfig.load(path)
                replaceConfigRoutes(try expandConfig(cfg.routes ?? []))
                print("OSC loaded routes from \(path)")
            case "/livebus/routes":
                print("active routes:\n" + routeList().joined(separator: "\n"))
            default:
                throw LBError("unknown OSC address \(m.address)")
            }
        } catch {
            print("OSC error: \(error)")
        }
    }

    // MARK: stato

    /// Una volta al secondo: scadenza dei device spariti, statistiche, file di stato.
    func tick() {
        let t = now()
        lock.lock()
        if book.expire(now: t, ttl: Router.ownerTTL) { applyLocked(); print("expired devices removed") }
        let owners = book.owners
        lock.unlock()

        lb_engine_collect_garbage(engine)
        busPeaks.withUnsafeMutableBufferPointer { lb_engine_get_bus_peaks(engine, $0.baseAddress, UInt32($0.count)) }
        for i in outputs.indices {
            lb_engine_get_output_stats(engine, UInt32(i), &lastStats[i])
            if lastStats[i].peak > 1.0 {
                if !clipping(i) { print("CLIP on \(outputs[i].id): peak \(linToDbString(lastStats[i].peak)) dBFS — lower the track or use @-6") }
                lastClip[i] = t
            }
        }

        guard let path = statusPath else { return }
        var peaks: [String: Double] = [:]
        for (i, p) in busPeaks.enumerated() where p > 0.0001 { peaks[String(i + 1)] = (20 * log10(Double(p)) * 10).rounded() / 10 }
        let outs: [[String: Any]] = outputs.enumerated().map { i, o in
            let st = lastStats[i]
            return ["id": o.id, "device": o.device.name, "channels": o.device.outputChannels,
                    "running": st.running != 0, "underruns": st.underruns, "overruns": st.overruns,
                    "ppm": ((st.ppm_ff + st.ppm_pi) * 100).rounded() / 100, "latencyMs": (o.latencyMs * 10).rounded() / 10, "clip": clipping(i)]
        }
        var ow: [String: Any] = [:]
        for (id, o) in owners where o.expires {
            ow[id] = ["src": o.src, "dest": o.dest, "routes": o.routes.count, "error": o.error ?? ""]
        }
        let doc: [String: Any] = [
            "version": 1, "session": session, "time": t,
            "bus": ["name": bus.name, "channels": bus.inputChannels],
            "outputs": outs, "owners": ow, "busPeaksDb": peaks,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Righe brevi per il menu dell'app.
    func outputLines() -> [String] {
        outputs.enumerated().map { i, o in
            let st = lastStats[i]
            let state = st.running != 0 ? "ok" : "starting"
            let xr = st.underruns + st.overruns
            return "\(o.id): \(o.device.name) — \(o.device.outputChannels) ch, \(state)"
                + (xr > 0 ? ", xrun \(st.underruns)/\(st.overruns)" : "")
                + String(format: ", %.0f ms", o.latencyMs)
                + (clipping(i) ? ", CLIP!" : "")
        }
    }

    var deviceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return book.owners.values.filter { $0.expires }.count
    }

    var hasXruns: Bool { lastStats.contains { $0.underruns + $0.overruns > 0 } }
    var hasClip: Bool { outputs.indices.contains { clipping($0) } }

    func summary() -> String {
        var s = "bus: \(bus.name) — \(bus.inputChannels) channels, \(Int(bus.sampleRate)) Hz, buffer \(bus.bufferFrames)\n"
        // il driver LiveBus ha il volume disattivato nel percorso audio: il cursore non conta
        if !bus.uid.hasPrefix("LiveBus") && !bus.uid.hasPrefix("R4F"), let db = CoreAudioHelpers.outputVolumeDb(bus.id), db < -0.05 {
            s += "  warning: the bus output volume is \(String(format: "%.1f", db)) dB: the DAW signal arrives attenuated. "
            s += "Turn it all the way up in Audio MIDI Setup.\n"
        }
        for o in outputs {
            s += "output \(o.id): \(o.device.name) — \(o.device.outputChannels) channels, \(Int(o.device.sampleRate)) Hz, "
            s += "buffer \(o.device.bufferFrames), ring \(o.target) frame, latency ≈ \(String(format: "%.1f", o.latencyMs)) ms\n"
            if o.device.sampleRate != bus.sampleRate {
                s += "  warning: sample rate differs from the bus, the resampler converts \(Int(bus.sampleRate))→\(Int(o.device.sampleRate))\n"
            }
        }
        if let p = statusPath { s += "status file (R4F Out device in Live, other apps): \(p)\n" }
        let r = routeList()
        s += r.isEmpty ? "no routes" : "routes:\n" + r.joined(separator: "\n")
        return s
    }

    func statusReport() -> String {
        let active = busPeaks.enumerated().filter { $0.element > 0.001 }.map { "\($0.offset + 1):\(linToDbString($0.element))" }
        var lines = ["bus      " + (active.isEmpty ? "silence" : active.prefix(16).joined(separator: " ")
            + (active.count > 16 ? " …(+\(active.count - 16))" : ""))]
        for (i, o) in outputs.enumerated() {
            let st = lastStats[i]
            let state = st.running != 0 ? "ok " : "..."
            lines.append(o.id.padding(toLength: 8, withPad: " ", startingAt: 0)
                + String(format: " %@ ring %5llu err %+7.1f  drift %+8.2f ppm (ff %+7.2f, pi %+7.2f)  xrun %llu/%llu  ch %u  peak %@",
                         state, st.fill, st.error, st.ppm_ff + st.ppm_pi, st.ppm_ff, st.ppm_pi,
                         st.underruns, st.overruns, st.active_channels, linToDbString(st.peak))
                + (clipping(i) ? "  CLIP" : ""))
        }
        lock.lock()
        let devs = book.owners.filter { $0.value.expires }.count
        lock.unlock()
        if devs > 0 { lines.append("R4F Out devices connected: \(devs)") }
        return lines.joined(separator: "\n")
    }
}
