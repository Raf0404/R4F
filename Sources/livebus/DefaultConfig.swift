import CoreAudio
import Foundation

/// Configurazione iniziale creata al primo avvio dell'app, partendo dai dispositivi presenti:
/// - bus: LiveBus (il più grande), altrimenti BlackHole, altrimenti il primo virtuale con ingressi;
/// - uscite: tutte le schede fisiche (niente virtuali né aggregati); l'uscita integrata si chiama "mac";
/// - rotta "Main" bus 1-2 → mac:1-2: l'uscita principale della DAW (di solito 1-2) si sente dagli altoparlanti.
enum DefaultConfig {
    static func make(devices: [AudioDevice]) throws -> LiveBusConfig {
        let inputs = devices.filter { $0.inputChannels > 0 }
        let bus = inputs.first { $0.name == "R4F BUS" || $0.uid.hasPrefix("R4F BUS") }
            ?? inputs.filter { $0.uid.hasPrefix("LiveBus") }.max { $0.inputChannels < $1.inputChannels }
            ?? inputs.filter { $0.name.localizedCaseInsensitiveContains("BlackHole") }.max { $0.inputChannels < $1.inputChannels }
            ?? inputs.first { $0.isVirtual }
        guard let busDev = bus else {
            throw LBError("nessun bus virtuale trovato: installa il driver (sudo driver/install.sh 256)")
        }
        let chosen = devices.filter { $0.outputChannels > 0 && !$0.isVirtual && !$0.isAggregate && $0.id != busDev.id }
        let names = outputNames(chosen.map { outputBase($0, ref: $0.name) })
        let outputs = zip(chosen, names).map { OutputSpec(id: $1, device: label($0, devices), delayMs: nil) }
        if outputs.isEmpty {
            throw LBError("nessuna scheda di uscita fisica trovata")
        }
        var routes: [RouteSpec] = []
        if let mac = outputs.first(where: { $0.id == "mac" }),
           let dev = devices.first(where: { $0.uid == mac.device || $0.name == mac.device }), dev.outputChannels >= 2 {
            routes.append(RouteSpec(from: ChannelList([1, 2]), to: "mac:1-2", gainDb: nil, name: "Main", mode: "pair"))
        }
        return LiveBusConfig(bus: label(busDev, devices), outputs: outputs, routes: routes, bufferFrames: 256,
                             safetyFrames: nil, feedForward: nil, alignOutputs: nil, oscPort: 7400, statusFile: nil)
    }

    /// Nome leggibile se univoco, altrimenti l'UID (es. due dispositivi "NDI Audio").
    static func label(_ d: AudioDevice, _ all: [AudioDevice]) -> String {
        all.filter { $0.name == d.name }.count == 1 ? d.name : d.uid
    }

    /// Nome automatico di un'uscita: "mac" per l'uscita integrata, altrimenti la prima parola del
    /// dispositivo in minuscolo ("Fireface UCX II" → "fireface", "BlackHole 64ch" → "blackhole").
    static func outputBase(_ d: AudioDevice?, ref: String) -> String {
        if let d = d, d.isBuiltIn { return "mac" }
        let id = shortId(d?.name ?? ref)
        return id.isEmpty ? "out" : id
    }

    /// Nomi univoci in ordine: il secondo con la stessa base diventa "fireface2", poi "fireface3"…
    static func outputNames(_ bases: [String]) -> [String] {
        var used = Set<String>(), out: [String] = []
        for b in bases {
            var id = b, n = 2
            while used.contains(id) { id = b + String(n); n += 1 }
            used.insert(id)
            out.append(id)
        }
        return out
    }

    /// "Fireface UCX II (23456789)" → "fireface"
    static func shortId(_ name: String) -> String {
        let first = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? ""
        let ascii = first.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
        return String(ascii.prefix(10))
    }

    static func write(_ cfg: LiveBusConfig, to path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(cfg)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
