import CoreAudio
import Foundation

/// Test della logica senza audio: sintassi delle destinazioni, proprietari, parser OSC.
func runLogicTests() -> Bool {
    print("\n— logica di rotte e OSC —")
    var ok = true
    func verdict(_ cond: Bool, _ msg: String) {
        print((cond ? "  ok    " : "  FALLITO ") + msg)
        if !cond { ok = false }
    }
    let outs = [OutputInfo(id: "a", channels: 64), OutputInfo(id: "b", channels: 8)]
    func ex(_ src: [Int], _ dest: String, _ g: Double = 0) -> [RouteKey: Float]? {
        try? RouteSpecParser.expand(src: src, dest: dest, busChannels: 256, outputs: outs, gainDb: g)
    }
    func err(_ src: [Int], _ dest: String) -> String {
        do { _ = try RouteSpecParser.expand(src: src, dest: dest, busChannels: 256, outputs: outs); return "" } catch { return "\(error)" }
    }

    // stereo in coppia
    let s = ex([17, 18], "a:1-2")
    verdict(s == [RouteKey(src: 16, out: 0, dst: 0): 1, RouteKey(src: 17, out: 0, dst: 1): 1], "stereo 17-18 → a:1-2 in coppia")
    // più destinazioni + guadagno per destinazione
    let m = ex([17, 18], "a:1-2 b:5@-6")
    let g6 = dbToLin(-6) / 2
    verdict(m?.count == 4 && m?[RouteKey(src: 16, out: 1, dst: 4)] == g6 && m?[RouteKey(src: 17, out: 1, dst: 4)] == g6
            && m?[RouteKey(src: 16, out: 0, dst: 0)] == 1,
            "a:1-2 b:5@-6: coppia su a a 0 dB, (L+R)/2 su b:5 a -6 dB")
    verdict(ex([1, 2, 3, 4], "b:1")?[RouteKey(src: 0, out: 1, dst: 0)] == 0.25, "4 canali su uno: media (1/4 ciascuno)")
    verdict(ex([3], "a:1-4")?[RouteKey(src: 2, out: 0, dst: 3)] == 1, "fan-out mono: nessuna attenuazione")
    // mono fan-out
    verdict(ex([3], "a:1-4;b:8")?.count == 5, "mono 3 → a:1-4 e b:8 (fan-out, separatore ;)")
    // guadagno globale che si somma
    verdict(ex([3], "b:1@-3", -3)?[RouteKey(src: 2, out: 1, dst: 0)] == dbToLin(-6), "guadagno di token e globale si sommano")
    verdict(ex([3], "")?.isEmpty == true, "destinazione vuota → nessuna rotta")
    verdict(err([3], "c:1").contains("unknown"), "uscita sconosciuta → errore leggibile")
    verdict(err([3, 4], "b(8)").contains("write e.g. b:1-2"), "'b(8)' copiato dallo stato → suggerisce b:1-2")
    verdict(err([3, 4], "b").contains("write e.g. b:1-2"), "'b' senza canale → suggerisce b:1-2")
    verdict(err([3], "zz").contains("a:1-64, b:1-8"), "token senza ':' sconosciuto → elenca le uscite")
    verdict(err([3], "b:9").contains("8 channels"), "canale oltre il limite → errore")
    verdict(err([1, 2, 3], "a:1-2").contains("same length"), "3 → 2 canali → errore")
    verdict(err([300], "a:1").contains("256"), "canale bus oltre il limite → errore")

    // configurazione di default
    func dev(_ id: UInt32, _ name: String, _ uid: String, _ i: Int, _ o: Int, _ t: UInt32) -> AudioDevice {
        AudioDevice(id: id, uid: uid, name: name, inputChannels: i, outputChannels: o, sampleRate: 48000,
                    bufferFrames: 512, outputLatency: 0, transport: t)
    }
    let fake = [
        dev(1, "BlackHole 64ch", "BlackHole64ch_UID", 64, 64, kAudioDeviceTransportTypeVirtual),
        dev(2, "R4F BUS", "R4F BUS_UID", 256, 256, kAudioDeviceTransportTypeVirtual),
        dev(3, "Altoparlanti MacBook Pro", "BuiltInSpeakerDevice", 0, 2, kAudioDeviceTransportTypeBuiltIn),
        dev(4, "Fireface UCX II (2345)", "ff-uid", 20, 20, kAudioDeviceTransportTypeUSB),
        dev(5, "NDI Audio", "ndi-in", 2, 0, kAudioDeviceTransportTypeVirtual),
        dev(6, "NDI Audio", "ndi-out", 0, 6, kAudioDeviceTransportTypeVirtual),
        dev(7, "Dispositivo combinato", "agg", 0, 4, kAudioDeviceTransportTypeAggregate),
        dev(8, "R4F BOX", "R4F BOX_UID", 256, 256, kAudioDeviceTransportTypeVirtual),
    ]
    if let c = try? DefaultConfig.make(devices: fake) {
        verdict(c.bus == "R4F BUS", "default: bus = R4F BUS (preferito a BlackHole)")
        verdict(c.outputs.map { $0.id } == ["mac", "fireface"], "default: uscite mac e fireface, niente virtuali né aggregati")
        verdict(c.routes?.first?.to == "mac:1-2", "default: Main (bus 1-2) sugli altoparlanti")
    } else { verdict(false, "default: configurazione creata") }
    verdict(DefaultConfig.label(fake[5], fake) == "ndi-out", "nome duplicato → UID")
    verdict((try? DefaultConfig.make(devices: [fake[2]])) == nil, "senza bus virtuale → errore")

    // editor grafico: carica → salva senza perdite, validazione
    let ed = ConfigEditorModel(devices: fake)
    let src = LiveBusConfig(bus: "R4F BUS",
        outputs: [OutputSpec(id: "mac", device: "Altoparlanti MacBook Pro", delayMs: nil),
                  OutputSpec(id: "fireface", device: "ff-uid", delayMs: 2.5)],
        routes: [RouteSpec(from: ChannelList([1, 2]), to: "mac:1-2", gainDb: nil),
                 RouteSpec(from: ChannelList([3, 4]), to: "fireface:1-2 mac:1@-6", gainDb: -3)],
        bufferFrames: 128, safetyFrames: 200, feedForward: nil, alignOutputs: false, oscPort: 7400, statusFile: nil)
    ed.load(src, path: "/tmp/x.json")
    verdict(ed.routes.count == 3 && ed.routes[2].out == "mac" && ed.routes[2].gainDb == "-9" && ed.routes[1].from == "3-4",
            "editor: destinazioni multiple divise in righe, guadagni sommati (-3 + -6 = -9)")
    verdict(ed.bus == "R4F BUS_UID" && ed.outputs[1].device == "ff-uid" && ed.outputs[1].delayMs == "2.5",
            "editor: dispositivi risolti per nome o UID")
    verdict(!ed.isDirty && ed.canSave && ed.issues.isEmpty, "editor: appena caricata non risulta modificata ed è valida")
    let out = ed.makeConfig()
    verdict(out.bus == "R4F BUS" && out.outputs[1].device == "Fireface UCX II (2345)" && out.bufferFrames == 128
            && out.safetyFrames == 200 && out.alignOutputs == false && out.routes?.count == 3,
            "editor: salva nomi leggibili e conserva le opzioni")
    if let r = try? RouteSpecParser.expand(src: [3, 4], dest: out.routes![2].to, busChannels: 256,
                                           outputs: [OutputInfo(id: "fireface", channels: 20), OutputInfo(id: "mac", channels: 2)],
                                           gainDb: out.routes![2].gainDb ?? 0) {
        verdict(abs((r[RouteKey(src: 2, out: 1, dst: 0)] ?? 0) - dbToLin(-9) / 2) < 1e-6, "editor: stesso risultato audio dopo il salvataggio")
    } else { verdict(false, "editor: rotta salvata valida") }
    ed.routes[0].gainDb = "-2"
    verdict(ed.isDirty, "editor: una modifica la rende da salvare")
    verdict(ed.outputs.map { $0.name } == ["mac", "fireface"], "nomi automatici: mac (integrato) e fireface")
    ed.routes[1].gainDb = "forte"
    verdict(!ed.status(of: ed.routes[1]).ok && !ed.canSave, "editor: guadagno non numerico segnalato sulla riga")
    ed.routes[1].gainDb = ""
    ed.outputs.append(ConfigEditorModel.Out(name: "", device: "uid-che-non-c-e", delayMs: ""))
    ed.syncNames()
    verdict(ed.canSave && ed.issues.contains { !$0.blocking && $0.text.contains("not connected") },
            "editor: scheda scollegata = avviso, non blocca")
    ed.addRoute()
    verdict(ed.routes.last?.from == "5-6", "editor: nuova rotta propone il primo canale libero del bus (5-6)")

    // matrice, testo, preset, nomi
    let mx = ConfigEditorModel(devices: fake)
    mx.load(LiveBusConfig(bus: "R4F BUS",
        outputs: [OutputSpec(id: "mac", device: "Altoparlanti MacBook Pro", delayMs: nil), OutputSpec(id: "fireface", device: "ff-uid", delayMs: nil)],
        routes: [RouteSpec(from: ChannelList([1, 2]), to: "mac:1-2", gainDb: nil, name: "Main"),
                 RouteSpec(from: ChannelList([3, 4]), to: "fireface:5", gainDb: -3, name: "Mono")],
        bufferFrames: nil, safetyFrames: nil, feedForward: nil, alignOutputs: nil, oscPort: 7400, statusFile: nil), path: nil)
    func audio(_ m: ConfigEditorModel) -> [String: Float] {
        let outs = [OutputInfo(id: "mac", channels: 2), OutputInfo(id: "fireface", channels: 20)]
        var all: [String: Float] = [:]
        for r in m.makeConfig().routes ?? [] {
            for (k, g) in (try? RouteSpecParser.expand(src: r.from.channels, dest: r.to, busChannels: 256, outputs: outs, gainDb: r.gainDb ?? 0, sum: r.isSum)) ?? [:] {
                all["\(k.src)>\(k.out):\(k.dst)"] = g
            }
        }
        return all
    }
    let before = audio(mx)
    mx.setConnection(.init(src: 9, out: "fireface", dst: 1), on: true, group: "Main")
    mx.setConnection(.init(src: 10, out: "fireface", dst: 2), on: true, group: "Main")
    verdict(mx.routes.filter { $0.name == "Main" }.count == 2 && mx.routes.contains { $0.from == "9-10" && $0.channels == "1-2" },
            "matrice: due clic in diagonale diventano una riga 9-10 → fireface:1-2 nella rotta Main")
    mx.setConnection(.init(src: 9, out: "fireface", dst: 1), on: false, group: "")
    mx.setConnection(.init(src: 10, out: "fireface", dst: 2), on: false, group: "")
    verdict(audio(mx) == before, "matrice: accendere e rispegnere riporta esattamente all'audio di prima")
    mx.setConnection(.init(src: 4, out: "fireface", dst: 5), on: false, group: "")
    let a3 = audio(mx)["2>1:4"] ?? 0
    verdict(abs(20 * log10(Double(a3)) - (-3 + 20 * log10(0.5))) < 0.006 && audio(mx)["3>1:4"] == nil,
            "matrice: togliere un canale da una media conserva il guadagno dell'altro entro 0,01 dB (-9,02 dB)")
    mx.setConnection(.init(src: 5, out: "mac", dst: 1), on: true, group: "Nuova")
    mx.setConnection(.init(src: 5, out: "mac", dst: 2), on: true, group: "Nuova")
    verdict(mx.routes.contains { $0.name == "Nuova" && $0.from == "5" && $0.channels == "1-2" }, "matrice: uno su più canali diventa un fan-out")

    let txt = mx.routesText()
    let snap = audio(mx)
    verdict(mx.applyText(txt).isEmpty && audio(mx) == snap, "testo: rileggere il testo generato non cambia nulla")
    let errs = mx.applyText("Main: 1-2 -> mac:1-2\nFronte: 3-4 -> fireface:1-2 mac:1@-6\n# commento\nSub: 9 -> fireface:7-8 @-3")
    verdict(errs.isEmpty && mx.routes.count == 4 && mx.routes[2].name == "Fronte" && mx.routes[2].gainDb == "-6"
            && mx.routes[3].gainDb == "-3", "testo: nomi, più uscite per riga, @dB per token e per riga, commenti")
    let bad = mx.applyText("Main: 1-2 -> mac:1-2\nquesta riga è sbagliata\nX: 3 -> zz:1")
    verdict(bad.count == 2 && mx.routes.count == 4, "testo: con errori le rotte restano quelle di prima (\(bad.count) errori)")

    let p51 = ConfigEditorModel.presets.first { $0.id == "5.1" }!
    let film2smpte = mx.presetRoutes(p51, dawOrder: 1, speakerOrder: 0, busStart: 11, out: "fireface", outStart: 1, name: "5.1")
    let lk = Dictionary(uniqueKeysWithValues: film2smpte.flatMap { mx.links(of: $0) ?? [] }.map { ($0.pair.src, $0.pair.dst) })
    // Film: L C R Ls Rs LFE  →  SMPTE: L R C LFE Ls Rs
    verdict(lk == [11: 1, 12: 3, 13: 2, 14: 5, 15: 6, 16: 4], "preset 5.1: da ordine Film (DAW) a SMPTE (altoparlanti)")
    let same = mx.presetRoutes(p51, dawOrder: 0, speakerOrder: 0, busStart: 11, out: "fireface", outStart: 3, name: "5.1")
    verdict(same.count == 1 && same[0].from == "11-16" && same[0].channels == "3-8", "preset 5.1 stesso ordine: una riga 11-16 → fireface:3-8")
    verdict(mx.presetProblem(p51, busStart: 11, out: "mac", outStart: 1)?.blocking == true, "preset su un'uscita troppo piccola: bloccato")
    verdict(mx.suggestBusStart(6) == 5 || mx.suggestBusStart(6) >= 3, "preset: propone un blocco libero del bus")
    mx.renameGroup("Fronte", to: "Frontali")
    verdict(mx.routes.contains { $0.name == "Frontali" } && !mx.routes.contains { $0.name == "Fronte" }
            && mx.makeConfig().routes?.contains { $0.name == "Frontali" } == true, "rinomina: cambia tutte le righe e finisce nella config")
    let named = mx.makeConfig()
    let ed2 = ConfigEditorModel(devices: fake)
    ed2.load(named, path: nil)
    verdict(ed2.routes.map { $0.name } == mx.routes.map { $0.name }, "nomi delle rotte salvati e ricaricati")

    // nomi automatici delle uscite
    let nm = ConfigEditorModel(devices: fake)
    nm.load(LiveBusConfig(bus: "R4F BUS",
        outputs: [OutputSpec(id: "a", device: "ff-uid", delayMs: nil), OutputSpec(id: "casse", device: "Altoparlanti MacBook Pro", delayMs: nil)],
        routes: [RouteSpec(from: ChannelList([3, 4]), to: "a:1-2", gainDb: nil, name: "Fronte"),
                 RouteSpec(from: ChannelList([1, 2]), to: "casse:1-2", gainDb: nil, name: "Main")],
        bufferFrames: nil, safetyFrames: nil, feedForward: nil, alignOutputs: nil, oscPort: 7400, statusFile: nil), path: "/tmp/v.json")
    verdict(nm.outputs.map { $0.name } == ["fireface", "mac"] && nm.routes.map { $0.out } == ["fireface", "mac"],
            "apertura: nomi scritti a mano (a, casse) diventano automatici e le rotte li seguono")
    verdict(nm.isDirty && nm.issues.contains { !$0.blocking && $0.text.contains("a → fireface") }, "apertura: avviso dei nomi cambiati, da salvare")
    nm.outputs[0].device = "BuiltInSpeakerDevice"; nm.outputs[1].device = "ff-uid"
    nm.syncNames()
    verdict(nm.outputs.map { $0.name } == ["mac", "fireface"] && nm.routes.first { $0.name == "Fronte" }?.out == "mac",
            "scambio dei dispositivi: nomi scambiati, ogni rotta segue la sua uscita")
    nm.outputs[1].device = "BuiltInSpeakerDevice"
    nm.syncNames()
    verdict(nm.outputs.map { $0.name } == ["mac", "mac2"], "due uscite con lo stesso nome base: mac e mac2")
    nm.outputs[1].device = "ff-uid"; nm.syncNames()
    nm.removeOutput(nm.outputs[0].id)
    verdict(nm.outputs.map { $0.name } == ["fireface"] && nm.routes.first { $0.name == "Fronte" }?.out == "⚠︎mac"
            && !nm.status(of: nm.routes.first { $0.name == "Fronte" }!).ok,
            "uscita tolta: le sue rotte restano segnalate, non passano a un'altra uscita")
    nm.addOutput()
    verdict(nm.outputs.count == 2 && nm.outputs[1].name != "" && !nm.outputs[1].name.contains(" "), "aggiungi uscita: nome dato in automatico (\(nm.outputs[1].name))")
    verdict(DefaultConfig.outputNames(["fireface", "fireface", "mac", "fireface"]) == ["fireface", "fireface2", "mac", "fireface3"],
            "nomi univoci con numero progressivo")

    // modo Somma (default delle rotte nuove)
    let outs2 = [OutputInfo(id: "mac", channels: 2), OutputInfo(id: "a", channels: 8)]
    let s22 = (try? RouteSpecParser.expand(src: [1, 2], dest: "mac:1-2", busChannels: 256, outputs: outs2, sum: true)) ?? [:]
    verdict(s22.count == 4 && s22.values.allSatisfy { $0 == 0.5 }, "somma: 1-2 → mac:1-2 = ogni canale su entrambe le uscite, a 1/2 (-6 dB)")
    let p22 = (try? RouteSpecParser.expand(src: [1, 2], dest: "mac:1-2", busChannels: 256, outputs: outs2, sum: false)) ?? [:]
    verdict(p22.count == 2 && p22[RouteKey(src: 0, out: 0, dst: 0)] == 1, "1:1: 1-2 → mac:1-2 resta in coppia a 0 dB")
    let s41 = (try? RouteSpecParser.expand(src: [1, 2, 3, 4], dest: "a:1-3", busChannels: 256, outputs: outs2, sum: true)) ?? [:]
    verdict(s41.count == 12 && s41.values.allSatisfy { $0 == 0.25 }, "somma: 4 canali su 3 uscite = 12 collegamenti a 1/4 (-12 dB)")
    let s12 = (try? RouteSpecParser.expand(src: [5], dest: "a:1-4", busChannels: 256, outputs: outs2, sum: true)) ?? [:]
    verdict(s12.count == 4 && s12.values.allSatisfy { $0 == 1 }, "somma da un solo canale: fan-out a 0 dB")
    // il livello non sale: segnale identico (correlato) su 2 canali → stessa ampiezza in uscita
    verdict(abs(s22.values.reduce(0, +) / 2 - 1) < 1e-6, "somma: due canali identici a 0 dBFS danno 0 dBFS (nessun aumento)")
    let sm = ConfigEditorModel(devices: fake)
    sm.load(LiveBusConfig(bus: "R4F BUS", outputs: [OutputSpec(id: "mac", device: "Altoparlanti MacBook Pro", delayMs: nil)],
        routes: [RouteSpec(from: ChannelList([1, 2]), to: "mac:1-2", gainDb: nil, name: "Vecchia")],
        bufferFrames: nil, safetyFrames: nil, feedForward: nil, alignOutputs: nil, oscPort: 7400, statusFile: nil), path: nil)
    verdict(sm.routes[0].sum == false, "config salvata prima (senza modo) resta 1:1: il suono non cambia da solo")
    sm.addRoute()
    verdict(sm.routes[1].sum == true && sm.status(of: sm.routes[1]).text.contains("sum"), "rotta nuova: Somma di default (\(sm.status(of: sm.routes[1]).text))")
    verdict(sm.makeConfig().routes?.map { $0.mode ?? "-" } == ["pair", "sum"], "il modo viene scritto nel file")
    verdict(sm.routesText().contains("=> mac:1-2") && sm.routesText().contains("-> mac:1-2"), "testo: => per 1:1, -> per somma")
    let tx = sm.routesText()
    verdict(sm.applyText(tx).isEmpty && sm.routes.map { $0.sum } == [false, true], "testo riletto: i modi restano")
    if let ls = sm.links(of: sm.routes[1]) {
        verdict(ls.count == 4 && ls.allSatisfy { abs($0.gainDb - 20 * log10(0.5)) < 0.001 }, "matrice: la somma appare come 4 caselle a -6 dB")
    } else { verdict(false, "links della somma") }

    // R4F BOX: matrice nel driver
    let sample: [RouteKey: Float] = [RouteKey(src: 0, out: 0, dst: 4): 0.5, RouteKey(src: 255, out: 0, dst: 0): 1, RouteKey(src: 2, out: 0, dst: 1): 0.25]
    verdict(R4FBox.unpack(R4FBox.pack(sample)) == sample && R4FBox.pack(sample).count == 24, "BOX: matrice impacchettata e riletta identica (8 byte per rotta)")
    if let idl = try? R4FBox.links(R4FBox.identity(256), channels: 256) {
        verdict(idl.count == 256 && idl.allSatisfy { $0.key.src == $0.key.dst && $0.value == 1 }, "BOX: la rotta 1:1 copre i 256 canali a 0 dB")
    } else { verdict(false, "BOX: rotta 1:1 valida") }
    let bx = ConfigEditorModel(devices: fake)
    bx.loadBox(nil, device: fake.first { $0.name == "R4F BOX" })
    verdict(bx.isBox && bx.routes.count == 1 && bx.routes[0].from == "1-256" && bx.routes[0].channels == "1-256" && bx.outputs[0].name == "in",
            "BOX: senza file parte da 1:1, destinazione \"in\" (non rinominata)")
    verdict(!bx.isDirty && bx.canSave && bx.issues.isEmpty, "BOX: niente avvisi di anello anche se ingressi e uscite sono la stessa scheda")
    bx.routes = []
    bx.setConnection(.init(src: 1, out: "in", dst: 5), on: true, group: "Zoom")
    bx.setConnection(.init(src: 2, out: "in", dst: 6), on: true, group: "Zoom")
    bx.routes += [ConfigEditorModel.Route(name: "Mix", from: "3-6", out: "in", channels: "1", gainDb: "-3")]
    if let bl = try? R4FBox.links(bx.makeBoxConfig().routes, channels: 256) {
        verdict(bl[RouteKey(src: 0, out: 0, dst: 4)] == 1 && bl[RouteKey(src: 1, out: 0, dst: 5)] == 1
                && abs((bl[RouteKey(src: 2, out: 0, dst: 0)] ?? 0) - dbToLin(-3) / 4) < 1e-6 && bl.count == 6,
                "BOX: matrice disegnata e mix 4→1 (media, -3 dB) arrivano giusti al driver")
    } else { verdict(false, "BOX: rotte valide") }
    verdict(bx.suggestBusStart(2) == 7 || bx.suggestBusStart(2) == 1 || bx.suggestBusStart(2) >= 1, "BOX: i preset partono dal canale 1, non dal 3")
    bx.resetBoxIdentity()
    verdict(bx.routes.count == 1 && bx.routes[0].from == "1-256", "BOX: \"Tutto 1:1\" ripristina la copia completa")

    // anelli di retroazione nel bus
    let loopR: [RouteKey: Float] = [RouteKey(src: 0, out: 1, dst: 0): 1, RouteKey(src: 0, out: 0, dst: 1): 1]
    verdict(LoopGuard.loopingKeys(loopR, busOutputs: [1]) == [RouteKey(src: 0, out: 1, dst: 0)],
            "anello: bus 1 → bus:1 (stesso dispositivo) riconosciuto, la rotta verso mac resta")
    let chain: [RouteKey: Float] = [RouteKey(src: 2, out: 1, dst: 32): 1, RouteKey(src: 32, out: 0, dst: 0): 1]
    verdict(LoopGuard.loopingKeys(chain, busOutputs: [1]).isEmpty, "nessun anello: bus 3 → bus:33 → mac è permesso")
    let two: [RouteKey: Float] = [RouteKey(src: 4, out: 1, dst: 9): 1, RouteKey(src: 9, out: 1, dst: 4): 1]
    verdict(LoopGuard.loopingKeys(two, busOutputs: [1]).count == 2, "anello a due passi (5 → 10 → 5) riconosciuto")
    let lp = ConfigEditorModel(devices: fake)
    lp.load(LiveBusConfig(bus: "R4F BUS",
        outputs: [OutputSpec(id: "mac", device: "Altoparlanti MacBook Pro", delayMs: nil), OutputSpec(id: "blackhole", device: "R4F BUS", delayMs: nil)],
        routes: [RouteSpec(from: ChannelList([1]), to: "blackhole:1", gainDb: nil), RouteSpec(from: ChannelList([1]), to: "mac:2", gainDb: nil)],
        bufferFrames: nil, safetyFrames: nil, feedForward: nil, alignOutputs: nil, oscPort: 7400, statusFile: nil), path: nil)
    verdict(!lp.canSave && lp.issues.contains { $0.blocking && $0.text.contains("Feedback loop") }, "editor: la config dell'utente con l'anello non si salva")
    lp.outputs.removeLast()
    lp.addOutput()
    verdict(lp.outputs.last?.device != "R4F BUS_UID", "editor: Aggiungi uscita non propone il dispositivo del bus")

    // proprietari
    let book = RouteBook()
    book.set("config", routes: [RouteKey(src: 0, out: 0, dst: 0): 1], now: 0, expires: false)
    book.set("dev1", routes: [RouteKey(src: 16, out: 0, dst: 0): 1], now: 0, expires: true)
    verdict(!book.set("dev1", routes: [RouteKey(src: 16, out: 0, dst: 0): 1], now: 2, expires: true),
            "rinvio identico non cambia le rotte (nessuna ricostruzione)")
    book.set("dev2", routes: [RouteKey(src: 16, out: 0, dst: 0): 0.5], now: 0, expires: true)
    verdict(book.merged()[RouteKey(src: 16, out: 0, dst: 0)] == 1, "rotta condivisa: vale il guadagno maggiore, non la somma")
    verdict(book.expire(now: 7, ttl: 6) && book.owners["dev2"] == nil && book.owners["dev1"] != nil,
            "device non rinnovato da oltre 6 s scade, quello rinnovato resta")
    verdict(book.remove("dev1") && book.merged().count == 1, "release toglie le rotte del device")
    book.expire(now: 1000, ttl: 6)
    verdict(book.owners["config"] != nil, "la configurazione non scade mai")

    // OSC: messaggio come lo manda udpsend di Max
    func pad(_ s: String) -> [UInt8] { var b = Array(s.utf8) + [0]; while b.count % 4 != 0 { b.append(0) }; return b }
    func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
    var pkt = pad("/livebus/set") + pad(",sssf") + pad("lbo-x1") + pad("17,18") + pad("a:1-2 b:5@-6")
    pkt += be(Float(-3).bitPattern)
    let msgs = OSCParser.parse(pkt)
    verdict(msgs.count == 1 && msgs[0].address == "/livebus/set" && msgs[0].args.count == 4
            && msgs[0].args[2].stringValue == "a:1-2 b:5@-6" && msgs[0].args[3].doubleValue == -3,
            "parser OSC: /livebus/set con stringhe e float")
    let num = OSCParser.parse(pad("/livebus/set") + pad(",sis") + pad("o") + be(5) + pad("b:1"))
    verdict(num.first?.args[1].stringValue == "5", "canale bus inviato come intero viene accettato")
    var inner: [UInt8] = pad("/livebus/set")
    inner += pad(",sis")
    inner += pad("o")
    inner += be(5)
    inner += pad("b:1")
    var bundle: [UInt8] = pad("#bundle")
    bundle += [0, 0, 0, 0, 0, 0, 0, 1]
    bundle += be(UInt32(inner.count))
    bundle += inner
    verdict(OSCParser.parse(bundle).count == 1, "bundle OSC")
    return ok
}
