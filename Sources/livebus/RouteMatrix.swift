import Foundation

/// Le tre viste delle rotte (Elenco, Matrice, Testo) lavorano sulle stesse righe.
/// La matrice e i preset passano per le "coppie" (bus → uscita:canale con guadagno) e poi
/// ricompattano in righe, conservando esattamente il guadagno di ogni collegamento.
extension ConfigEditorModel {
    struct Pair: Hashable {
        let src: Int        // canale del bus, 1-based
        let out: String     // nome dell'uscita
        let dst: Int        // canale dell'uscita, 1-based
    }

    struct Link {
        let pair: Pair
        let gainDb: Double
    }

    // MARK: coppie

    /// Collegamenti di una riga, con il guadagno effettivo (la media dei canali su uno è già inclusa).
    func links(of r: Route) -> [Link]? {
        guard status(of: r).ok, let src = try? ChannelList.parse(r.from) else { return nil }
        // stesso calcolo del router (somma o 1:1, media, guadagni)
        let token = "\(r.out):\(r.channels.replacingOccurrences(of: " ", with: ""))"
        guard let map = try? RouteSpecParser.expand(src: src, dest: token, busChannels: 1024,
                                                    outputs: [OutputInfo(id: r.out, channels: 1024)],
                                                    gainDb: gain(r), sum: r.sum) else { return nil }
        return map.map { Link(pair: Pair(src: $0.key.src + 1, out: r.out, dst: $0.key.dst + 1), gainDb: 20 * log10(Double($0.value))) }
    }

    /// Chi possiede ogni collegamento (indice della riga) e con che guadagno.
    func connectionMap() -> [Pair: (row: Int, gainDb: Double)] {
        var m: [Pair: (Int, Double)] = [:]
        for (i, r) in routes.enumerated() {
            for l in links(of: r) ?? [] where m[l.pair] == nil { m[l.pair] = (i, l.gainDb) }
        }
        return m
    }

    /// Righe minime che producono esattamente questi collegamenti, tutte con lo stesso nome.
    /// Mai righe "molti su uno" (cambierebbero il guadagno per la media): solo coppie e fan-out.
    func compress(_ links: [Link], name: String) -> [Route] {
        var rows: [Route] = []
        let groups = Dictionary(grouping: links) { "\($0.pair.out)|\(Int(($0.gainDb * 100).rounded()))" }
        for key in groups.keys.sorted() {
            let ls = groups[key]!
            let out = ls[0].pair.out
            let g = ls[0].gainDb
            let gs = abs(g) < 0.005 ? "" : fmt((g * 100).rounded() / 100)
            var bySrc: [Int: [Int]] = [:]
            for l in ls { bySrc[l.pair.src, default: []].append(l.pair.dst) }
            var singles: [(Int, Int)] = []
            for src in bySrc.keys.sorted() {
                let dsts = Array(Set(bySrc[src]!)).sorted()
                if dsts.count > 1 {
                    rows.append(Route(name: name, from: "\(src)", out: out, channels: ChannelList.format(dsts), gainDb: gs))
                } else {
                    singles.append((src, dsts[0]))
                }
            }
            // tutti gli uno-a-uno in una riga sola: le liste possono essere in qualsiasi ordine
            // (es. 5.1 Film → SMPTE: 3-8 → 1,3,2,5-6,4); stesso numero di canali = coppie, mai media
            singles.sort { ($0.0, $0.1) < ($1.0, $1.1) }
            if !singles.isEmpty {
                rows.append(Route(name: name, from: ChannelList.format(singles.map { $0.0 }), out: out,
                                  channels: ChannelList.format(singles.map { $0.1 }), gainDb: gs))
            }
        }
        return rows
    }

    // MARK: matrice

    func isConnected(_ p: Pair) -> Bool { connectionMap()[p] != nil }

    /// Accende o spegne un collegamento. Spegnendo, la riga che lo conteneva viene riscritta senza;
    /// accendendo, il collegamento entra nella rotta `group` (le sue righe vengono ricompattate).
    func setConnection(_ p: Pair, on: Bool, group: String) {
        if on {
            guard !isConnected(p) else { return }
            var keep: [Route] = [], merged: [Link] = [Link(pair: p, gainDb: 0)]
            var insertAt: Int?
            for (i, r) in routes.enumerated() {
                if r.name == group, let ls = links(of: r) {
                    merged += ls
                    if insertAt == nil { insertAt = keep.count }
                    _ = i
                } else {
                    keep.append(r)
                }
            }
            let rows = compress(merged, name: group)
            keep.insert(contentsOf: rows, at: insertAt ?? keep.count)
            routes = keep
        } else {
            var result: [Route] = []
            for r in routes {
                guard let ls = links(of: r), ls.contains(where: { $0.pair == p }) else { result.append(r); continue }
                result += compress(ls.filter { $0.pair != p }, name: r.name)
            }
            routes = result
        }
    }

    /// Nomi delle rotte in ordine di apparizione.
    var groupNames: [String] {
        var seen = Set<String>(), out: [String] = []
        for r in routes where seen.insert(r.name).inserted { out.append(r.name) }
        return out
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(routes.map { $0.name })
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: testo

    /// Una riga per rotta:  Nome: 3-4 -> a:1-2 @-3   (-> somma, => 1:1)
    func routesText() -> String {
        routes.map { r in
            let g = r.gainDb.trimmingCharacters(in: .whitespaces)
            let head = r.name.isEmpty ? "" : "\(r.name): "
            return "\(head)\(r.from) \(r.sum ? "->" : "=>") \(r.out):\(r.channels)" + (g.isEmpty ? "" : " @\(g)")
        }.joined(separator: "\n")
    }

    /// Legge il testo; se è tutto valido sostituisce le rotte e ritorna [], altrimenti gli errori per riga.
    @discardableResult
    func applyText(_ text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"^\s*(?:([^:>=]+?)\s*:\s*)?([0-9][0-9,\-\s]*?)\s*(=>|->|→|>)\s*(.+?)\s*$"#)
        var rows: [Route] = [], errors: [String] = []
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                errors.append("line \(n + 1): write  Name: bus channels -> output:channels  (e.g. Front: 3-4 -> a:1-2)")
                continue
            }
            let name = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
            let from = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: " ", with: "")
            let isSum = ns.substring(with: m.range(at: 3)) != "=>"
            var tokens = ns.substring(with: m.range(at: 4)).split(whereSeparator: { $0 == " " || $0 == ";" }).map(String.init)
            var lineGain = 0.0
            if let gi = tokens.firstIndex(where: { $0.hasPrefix("@") }) {
                lineGain = Double(tokens[gi].dropFirst().replacingOccurrences(of: ",", with: ".")
                    .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)) ?? .nan
                tokens.remove(at: gi)
                if lineGain.isNaN { errors.append("line \(n + 1): invalid gain"); continue }
            }
            if tokens.isEmpty { errors.append("line \(n + 1): missing destination"); continue }
            for tok in tokens {
                var body = tok, g = lineGain
                if let at = body.firstIndex(of: "@") {
                    guard let v = Double(body[body.index(after: at)...].replacingOccurrences(of: ",", with: ".")) else {
                        errors.append("line \(n + 1): invalid gain in '\(tok)'"); continue
                    }
                    g += v
                    body = String(body[..<at])
                }
                let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
                let r = Route(name: name, from: from, out: parts.first ?? "", channels: parts.count > 1 ? parts[1] : "",
                              gainDb: g == 0 ? "" : fmt(g), sum: isSum)
                let st = status(of: r)
                if !st.ok { errors.append("line \(n + 1): \(st.text)") }
                rows.append(r)
            }
        }
        if errors.isEmpty { routes = rows }
        return errors
    }

    // MARK: preset

    struct Preset: Identifiable {
        let id: String
        let title: String
        /// ordini dei canali disponibili: "SMPTE/ITU", "Film"…; se uno solo, l'ordine non si sceglie
        let orders: [(String, [String])]
        var count: Int { orders[0].1.count }
        var hasOrders: Bool { orders.count > 1 }
    }

    static let presets: [Preset] = {
        func nums(_ n: Int, _ prefix: String = "") -> [String] { (1...n).map { prefix + String($0) } }
        func acn(_ n: Int) -> [String] { (0..<n).map { "ACN \($0)" } }
        return [
            Preset(id: "stereo", title: "Stereo (2)", orders: [("", ["L", "R"])]),
            Preset(id: "lcr", title: "LCR (3)", orders: [("SMPTE/ITU", ["L", "R", "C"]), ("Film", ["L", "C", "R"])]),
            Preset(id: "quad", title: "Quad (4)", orders: [("", ["L", "R", "Ls", "Rs"])]),
            Preset(id: "5.0", title: "5.0 (5)", orders: [("SMPTE/ITU", ["L", "R", "C", "Ls", "Rs"]),
                                                       ("Film", ["L", "C", "R", "Ls", "Rs"])]),
            Preset(id: "5.1", title: "5.1 (6)", orders: [("SMPTE/ITU", ["L", "R", "C", "LFE", "Ls", "Rs"]),
                                                       ("Film", ["L", "C", "R", "Ls", "Rs", "LFE"])]),
            Preset(id: "7.1", title: "7.1 (8)", orders: [("SMPTE/ITU", ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"]),
                                                       ("Film", ["L", "C", "R", "Ls", "Rs", "Lrs", "Rrs", "LFE"])]),
            Preset(id: "7.1.4", title: "7.1.4 (12)", orders: [
                ("SMPTE/ITU", ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs", "Ltf", "Rtf", "Ltr", "Rtr"]),
                ("Film", ["L", "C", "R", "Ls", "Rs", "Lrs", "Rrs", "LFE", "Ltf", "Rtf", "Ltr", "Rtr"])]),
            Preset(id: "ring8", title: "Ring of 8 (octophony)", orders: [("", nums(8))]),
            Preset(id: "amb1", title: "Ambisonics 1st order (4)", orders: [("", acn(4))]),
            Preset(id: "amb2", title: "Ambisonics 2nd order (9)", orders: [("", acn(9))]),
            Preset(id: "amb3", title: "Ambisonics 3rd order (16)", orders: [("", acn(16))]),
        ]
    }()

    /// Primo canale del bus da cui ci sono `n` canali liberi (dal 3: 1-2 è l'uscita principale della DAW).
    func suggestBusStart(_ n: Int) -> Int {
        let used = Set(connectionMap().keys.map { $0.src })
        let limit = busChannels ?? 256
        var s = isBox ? 1 : 3
        while s + n - 1 <= limit {
            if !(s..<(s + n)).contains(where: { used.contains($0) }) { return s }
            s += 1
        }
        return 3
    }

    /// Righe del preset: il canale con etichetta X nella DAW va sull'altoparlante con etichetta X.
    func presetRoutes(_ p: Preset, dawOrder: Int, speakerOrder: Int, busStart: Int, out: String, outStart: Int,
                      name: String, gainDb: Double = 0) -> [Route] {
        let daw = p.orders[min(dawOrder, p.orders.count - 1)].1
        let spk = p.orders[min(speakerOrder, p.orders.count - 1)].1
        var ls: [Link] = []
        for (i, label) in daw.enumerated() {
            guard let j = spk.firstIndex(of: label) else { continue }
            ls.append(Link(pair: Pair(src: busStart + i, out: out, dst: outStart + j), gainDb: gainDb))
        }
        return compress(ls, name: name)
    }

    /// nil = tutto a posto; blocking = il preset non si può applicare.
    func presetProblem(_ p: Preset, busStart: Int, out: String, outStart: Int) -> (text: String, blocking: Bool)? {
        let n = p.count
        if busStart < 1 { return ("bus channels start at 1", true) }
        if let b = busChannels, busStart + n - 1 > b { return ("the bus has \(b) channels: \(busStart)-\(busStart + n - 1) needed", true) }
        if out.isEmpty { return ("choose an output", true) }
        if outStart < 1 { return ("output channels start at 1", true) }
        if let oc = channels(ofOutput: out), outStart + n - 1 > oc {
            return ("\(out) has \(oc) channels: \(outStart)-\(outStart + n - 1) needed", true)
        }
        let busy = Set(connectionMap().keys.map { $0.src })
        if (busStart..<(busStart + n)).contains(where: { busy.contains($0) }) {
            return ("some of bus channels \(busStart)-\(busStart + n - 1) are already in use: the routes are added", false)
        }
        return nil
    }
}

extension ConfigEditorModel {
    /// Rinomina tutte le righe di una rotta.
    func renameGroup(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        for i in routes.indices where routes[i].name == old { routes[i].name = n }
    }
}
