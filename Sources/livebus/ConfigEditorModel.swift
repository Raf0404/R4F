import CoreAudio
import Foundation

/// Stato modificabile dell'editor grafico. Tiene i campi come testo (come li scrive l'utente),
/// li valida riga per riga con lo stesso parser del router e li trasforma in LiveBusConfig.
final class ConfigEditorModel: ObservableObject {
    struct Out: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var device: String      // UID (o il testo originale se il dispositivo non c'è)
        var delayMs: String
    }

    struct Route: Identifiable, Equatable {
        let id = UUID()
        var name: String = ""   // nome libero, es. "Fronte"
        var from: String        // canali del bus, es. "3-10"
        var out: String         // nome dell'uscita
        var channels: String    // canali dell'uscita, es. "1-8"
        var gainDb: String
        /// true = Somma (ogni canale su tutte le destinazioni, a 1/N); false = 1:1 in coppia
        var sum: Bool = false
    }

    struct Issue: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let blocking: Bool
    }

    static let bufferChoices = [0, 64, 128, 256, 512, 1024]   // 0 = quello del dispositivo

    @Published var bus = ""
    @Published var outputs: [Out] = []
    @Published var routes: [Route] = []
    @Published var bufferFrames = 256
    @Published var alignOutputs = true
    @Published var feedForward = true
    @Published var oscPort = "7400"
    @Published private(set) var devices: [AudioDevice] = []
    @Published var path: String?
    private var safetyFrames: Int?
    private var statusFile: String?
    private var saved = ""

    init(devices: [AudioDevice] = CoreAudioHelpers.allDevices()) {
        self.devices = devices
    }

    // MARK: dispositivi

    func refreshDevices() { devices = CoreAudioHelpers.allDevices() }

    var inputDevices: [AudioDevice] { devices.filter { $0.inputChannels > 0 } }
    var outputDevices: [AudioDevice] { devices.filter { $0.outputChannels > 0 } }

    func device(_ ref: String) -> AudioDevice? {
        devices.first { $0.uid == ref } ?? devices.first { $0.name == ref }
    }

    func deviceLabel(_ d: AudioDevice, input: Bool) -> String {
        let n = input ? d.inputChannels : d.outputChannels
        let kind = d.isVirtual ? "virtuale" : d.isAggregate ? "aggregato" : d.isBuiltIn ? "integrato" : "scheda"
        let isBus = !input && d.uid == bus
        return "\(d.name)  —  \(n) can, \(kind)" + (isBus ? "  ⚠︎ è il bus" : "")
    }

    func channels(ofOutput name: String) -> Int? {
        guard let o = outputs.first(where: { $0.name == name }) else { return nil }
        return device(o.device)?.outputChannels
    }

    var busChannels: Int? { device(bus)?.inputChannels }

    // MARK: carica

    func load(_ cfg: LiveBusConfig, path: String?) {
        bus = device(cfg.bus)?.uid ?? cfg.bus
        outputs = cfg.outputs.map {
            Out(name: $0.id, device: device($0.device)?.uid ?? $0.device, delayMs: $0.delayMs.map { fmt($0) } ?? "")
        }
        routes = []
        for r in cfg.routes ?? [] {
            let from = r.from.channels.map(String.init).joined(separator: ",")
            let tokens = r.to.split(whereSeparator: { $0 == " " || $0 == ";" })
            for tok in tokens {
                var body = String(tok), g = r.gainDb ?? 0
                if let at = body.firstIndex(of: "@") {
                    g += Double(body[body.index(after: at)...].replacingOccurrences(of: "dB", with: "")) ?? 0
                    body = String(body[..<at])
                }
                let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
                routes.append(Route(name: r.name ?? "", from: compact(from), out: parts.first ?? "",
                                    channels: parts.count > 1 ? parts[1] : "", gainDb: g == 0 ? "" : fmt(g), sum: r.isSum))
            }
        }
        bufferFrames = cfg.bufferFrames ?? 0
        alignOutputs = cfg.alignOutputs ?? true
        feedForward = cfg.feedForward ?? true
        oscPort = String(cfg.oscPort ?? 7400)
        safetyFrames = cfg.safetyFrames
        statusFile = cfg.statusFile
        self.path = path
        markSaved()
        // nomi scritti a mano nelle configurazioni precedenti: si portano a quelli automatici
        renamedOnLoad = syncNames()
    }

    func loadFile(_ p: String) throws {
        load(try LiveBusConfig.load(p), path: p)
    }

    // MARK: R4F BOX

    /// true = questo modello descrive la matrice di R4F BOX (uscite → ingressi della stessa scheda).
    @Published var isBox = false

    func loadBox(_ cfg: BoxConfig?, device boxDev: AudioDevice?) {
        isBox = true
        let ref = boxDev?.name ?? R4FBox.name
        let ch = boxDev?.outputChannels ?? 256
        load(LiveBusConfig(bus: ref, outputs: [OutputSpec(id: R4FBox.inputsId, device: ref, delayMs: nil)],
                           routes: cfg?.routes ?? R4FBox.identity(ch), bufferFrames: nil, safetyFrames: nil,
                           feedForward: nil, alignOutputs: nil, oscPort: nil, statusFile: nil), path: R4FBox.path)
    }

    func resetBoxIdentity() {
        routes = []
        let ch = device(bus)?.outputChannels ?? 256
        for spec in R4FBox.identity(ch) {
            routes.append(Route(name: spec.name ?? "1:1", from: compact(ChannelList.format(spec.from.channels)),
                                out: R4FBox.inputsId, channels: "1-\(ch)", gainDb: ""))
        }
    }

    func makeBoxConfig() -> BoxConfig { BoxConfig(routes: makeConfig().routes ?? []) }

    private var boxIssues: [Issue] {
        var out: [Issue] = []
        if device(bus) == nil {
            out.append(Issue(text: "R4F BOX non è installato: la matrice si salva e verrà applicata quando lo installi.", blocking: false))
        }
        for (i, r) in routes.enumerated() {
            let st = status(of: r)
            let label = r.name.isEmpty ? "Rotta \(i + 1)" : "\(r.name) (riga \(i + 1))"
            if !st.ok { out.append(Issue(text: "\(label): \(st.text)", blocking: true)) }
        }
        if routes.isEmpty { out.append(Issue(text: "Nessuna rotta: tutti gli ingressi della BOX saranno muti.", blocking: false)) }
        return out
    }

    func loadDefaults() throws {
        refreshDevices()
        load(try DefaultConfig.make(devices: devices), path: nil)
        saved = ""   // una configurazione nuova è da salvare
    }

    // MARK: modifiche

    func addOutput() {
        // mai il dispositivo del bus: riscriverebbe nel bus quello che si sta leggendo
        let used = Set(outputs.map { $0.device } + [bus])
        let dev = outputDevices.first { !used.contains($0.uid) && !$0.isVirtual && !$0.isAggregate }
            ?? outputDevices.first { !used.contains($0.uid) && !$0.uid.hasPrefix("LiveBus") && !$0.uid.hasPrefix("R4F") }
            ?? outputDevices.first { !used.contains($0.uid) }
        outputs.append(Out(name: "", device: dev?.uid ?? "", delayMs: ""))
        syncNames()
    }

    // MARK: nomi automatici delle uscite

    /// Nomi rinominati all'apertura (vecchio → nuovo), da mostrare come avviso finché non si salva.
    @Published private(set) var renamedOnLoad: [(old: String, new: String)] = []

    /// I nomi delle uscite non si scrivono: derivano dal dispositivo. Se cambiano (dispositivo diverso,
    /// uscita tolta o aggiunta) le rotte che li usano vengono aggiornate insieme.
    @discardableResult
    func syncNames() -> [(old: String, new: String)] {
        if isBox { return [] }   // nella BOX l'unica destinazione sono i suoi ingressi: "in"
        let names = DefaultConfig.outputNames(outputs.map { DefaultConfig.outputBase(device($0.device), ref: $0.device) })
        var map: [String: String] = [:], changes: [(String, String)] = []
        for (i, n) in names.enumerated() where outputs[i].name != n {
            if !outputs[i].name.isEmpty { map[outputs[i].name] = n; changes.append((outputs[i].name, n)) }
            outputs[i].name = n
        }
        if !map.isEmpty {
            for i in routes.indices { if let n = map[routes[i].out] { routes[i].out = n } }
        }
        return changes
    }

    /// Toglie un'uscita: le sue rotte restano ma segnalate come senza uscita (non passano a un'altra).
    func removeOutput(_ id: UUID) {
        guard let o = outputs.first(where: { $0.id == id }) else { return }
        for i in routes.indices where routes[i].out == o.name { routes[i].out = "⚠︎" + o.name }
        outputs.removeAll { $0.id == id }
        syncNames()
    }

    func addRoute() {
        let out = outputs.first?.name ?? ""
        // propone il primo canale del bus libero dopo il Main
        let usedMax = routes.compactMap { (try? ChannelList.parse($0.from))?.max() }.max() ?? 2
        let next = isBox ? usedMax + 1 : max(3, usedMax + 1)
        // di default Somma: ogni canale su tutte le uscite della rotta, senza alzare il livello
        routes.append(Route(name: uniqueName("Rotta"), from: "\(next)-\(next + 1)", out: out, channels: "1-2", gainDb: "", sum: true))
    }

    // MARK: validazione

    private var outputInfo: [OutputInfo] {
        outputs.map { OutputInfo(id: $0.name, channels: device($0.device)?.outputChannels ?? 1024) }
    }

    /// Esito di una rotta: (ok, testo), es. (true, "8 collegamenti") o (false, "a ha 8 canali, non 9").
    func status(of r: Route) -> (ok: Bool, text: String) {
        do {
            let src = try ChannelList.parse(r.from)
            guard !r.out.isEmpty else { return (false, "scegli un'uscita") }
            guard !r.channels.trimmingCharacters(in: .whitespaces).isEmpty else { return (false, "scrivi i canali") }
            let g = r.gainDb.trimmingCharacters(in: .whitespaces)
            guard g.isEmpty || Double(g.replacingOccurrences(of: ",", with: ".")) != nil else { return (false, "guadagno non valido") }
            let token = "\(r.out):\(r.channels.replacingOccurrences(of: " ", with: ""))"
            let map = try RouteSpecParser.expand(src: src, dest: token, busChannels: busChannels ?? 1024,
                                                 outputs: outputInfo, gainDb: gain(r), sum: r.sum)
            let n = map.count
            var t = n == 1 ? "1 collegamento" : "\(n) collegamenti"
            let dst = (try? ChannelList.parse(r.channels))?.count ?? 0
            if r.sum && src.count > 1 {
                t += String(format: ", somma (%.0f dB)", 20 * log10(1 / Double(src.count)))
            } else if dst == 1 && src.count > 1 {
                t += ", media"
            }
            return (true, t)
        } catch {
            return (false, "\(error)")
        }
    }

    func gain(_ r: Route) -> Double {
        Double(r.gainDb.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    var issues: [Issue] {
        if isBox { return boxIssues }
        var out: [Issue] = []
        if bus.isEmpty { out.append(Issue(text: "Scegli il bus su cui suona la DAW.", blocking: true)) }
        else if device(bus) == nil { out.append(Issue(text: "Il bus \"\(bus)\" non è collegato ora.", blocking: false)) }
        if outputs.isEmpty { out.append(Issue(text: "Aggiungi almeno un'uscita.", blocking: true)) }
        if !renamedOnLoad.isEmpty {
            let list = renamedOnLoad.map { "\($0.old) → \($0.new)" }.joined(separator: ", ")
            out.append(Issue(text: "Nomi delle uscite resi automatici: \(list). Salva per applicare; "
                             + "aggiorna anche le destinazioni nei device R4F Out.", blocking: false))
        }
        var names = Set<String>()
        for o in outputs {
            let n = o.name
            if n.isEmpty { out.append(Issue(text: "Un'uscita non ha nome.", blocking: true)) }
            else if n.contains(where: { $0 == ":" || $0 == "@" || $0 == " " || $0 == "," }) {
                out.append(Issue(text: "Il nome \"\(n)\" non può contenere spazi, ':', '@' o ','.", blocking: true))
            } else if !names.insert(n).inserted {
                out.append(Issue(text: "Il nome \"\(n)\" è usato due volte.", blocking: true))
            }
            if o.device.isEmpty { out.append(Issue(text: "Scegli il dispositivo dell'uscita \"\(n)\".", blocking: true)) }
            else if device(o.device) == nil {
                out.append(Issue(text: "\"\(n)\": il dispositivo non è collegato ora (R4F riproverà ogni 5 s).", blocking: false))
            }
            if !o.delayMs.isEmpty, Double(o.delayMs.replacingOccurrences(of: ",", with: ".")) == nil {
                out.append(Issue(text: "Ritardo di \"\(n)\" non valido.", blocking: true))
            }
        }
        for o in outputs where !o.device.isEmpty && o.device == bus {
            out.append(Issue(text: "\"\(o.name)\" è lo stesso dispositivo del bus: ciò che vi mandi rientra nel bus.", blocking: false))
        }
        if let loop = loopDescription {
            out.append(Issue(text: "Anello di retroazione: \(loop). Il segnale tornerebbe nel bus da cui parte.", blocking: true))
        }
        let devs = outputs.map { $0.device }.filter { !$0.isEmpty }
        if Set(devs).count != devs.count { out.append(Issue(text: "Lo stesso dispositivo è usato da due uscite.", blocking: true)) }
        for (i, r) in routes.enumerated() {
            let st = status(of: r)
            let label = r.name.isEmpty ? "Rotta \(i + 1)" : "\(r.name) (riga \(i + 1))"
            if !st.ok { out.append(Issue(text: "\(label): \(st.text)", blocking: true)) }
            if r.name.contains(":") || r.name.contains(">") {
                out.append(Issue(text: "\(label): il nome non può contenere ':' o '>'.", blocking: true))
            }
        }
        if let p = Int(oscPort), p >= 0, p < 65536 {} else {
            out.append(Issue(text: "Porta OSC non valida.", blocking: true))
        }
        return out
    }

    var canSave: Bool { !issues.contains { $0.blocking } }

    /// Descrizione delle rotte che chiudono un anello nel bus, o nil.
    var loopDescription: String? {
        let busOuts = Set(outputs.indices.filter { !outputs[$0].device.isEmpty && outputs[$0].device == bus })
        guard !busOuts.isEmpty else { return nil }
        var keys: [RouteKey: Float] = [:]
        for r in routes {
            guard let oi = outputs.firstIndex(where: { $0.name == r.out }) else { continue }
            for l in links(of: r) ?? [] { keys[RouteKey(src: l.pair.src - 1, out: oi, dst: l.pair.dst - 1)] = 1 }
        }
        let bad = LoopGuard.loopingKeys(keys, busOutputs: busOuts)
        guard !bad.isEmpty else { return nil }
        return bad.sorted { ($0.src, $0.dst) < ($1.src, $1.dst) }.prefix(3)
            .map { "bus \($0.src + 1) → \(outputs[$0.out].name):\($0.dst + 1)" }.joined(separator: ", ")
    }

    // MARK: salva

    func makeConfig() -> LiveBusConfig {
        let outs = outputs.map { o -> OutputSpec in
            let ref = device(o.device).map { DefaultConfig.label($0, devices) } ?? o.device
            let d = Double(o.delayMs.replacingOccurrences(of: ",", with: "."))
            return OutputSpec(id: o.name, device: ref, delayMs: (d ?? 0) == 0 ? nil : d)
        }
        let rs = routes.compactMap { r -> RouteSpec? in
            guard let src = try? ChannelList.parse(r.from) else { return nil }
            let g = gain(r)
            let nm = r.name.trimmingCharacters(in: .whitespaces)
            return RouteSpec(from: ChannelList(src), to: "\(r.out):\(r.channels.replacingOccurrences(of: " ", with: ""))",
                             gainDb: g == 0 ? nil : g, name: nm.isEmpty ? nil : nm, mode: r.sum ? "sum" : "pair")
        }
        let busRef = device(bus).map { DefaultConfig.label($0, devices) } ?? bus
        return LiveBusConfig(bus: busRef, outputs: outs, routes: rs, bufferFrames: bufferFrames == 0 ? nil : bufferFrames,
                             safetyFrames: safetyFrames, feedForward: feedForward ? nil : false,
                             alignOutputs: alignOutputs ? nil : false, oscPort: Int(oscPort), statusFile: statusFile)
    }

    func save(to p: String) throws {
        try DefaultConfig.write(makeConfig(), to: p)
        path = p
        markSaved()
    }

    private func snapshot() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(makeConfig())).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func markSaved() { saved = snapshot(); renamedOnLoad = [] }
    /// dopo un salvataggio fatto fuori dal modello (es. box.json)
    func markSavedExternally() { markSaved() }
    var isDirty: Bool { snapshot() != saved }

    // MARK: utilità

    func fmt(_ d: Double) -> String {
        if d == d.rounded() { return String(Int(d)) }
        return String(format: "%.2f", d).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    /// "3,4,5,6" → "3-6"
    func compact(_ s: String) -> String {
        guard let list = try? ChannelList.parse(s), list.count > 1 else { return s }
        if zip(list, list.dropFirst()).allSatisfy({ $1 == $0 + 1 }) { return "\(list.first!)-\(list.last!)" }
        return s
    }
}
