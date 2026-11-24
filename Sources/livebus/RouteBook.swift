import Foundation

struct RouteKey: Hashable { let src: Int; let out: Int; let dst: Int }  // 0-based

struct OutputInfo { let id: String; let channels: Int }

/// Sintassi delle destinazioni: token separati da spazi o ';'
///   a:1-2      b:5@-6      c:1,3,5@-3.5
/// dove `a` è l'id dell'uscita, poi la lista di canali (1-based) e un guadagno opzionale in dB.
enum RouteSpecParser {
    static func parseDest(_ s: String, outputs: [OutputInfo]) throws -> [(out: Int, channels: [Int], gainDb: Double)] {
        var result: [(Int, [Int], Double)] = []
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "\t" || $0 == "\n" })
        for tok in tokens {
            var body = String(tok)
            var gain = 0.0
            if let at = body.firstIndex(of: "@") {
                let g = String(body[body.index(after: at)...])
                guard let v = Double(g.replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)) else {
                    throw LBError("guadagno non valido in '\(tok)'")
                }
                gain = v
                body = String(body[..<at])
            }
            if !body.contains(":") {
                // es. "bh" o "bh(64)" copiato dalla riga di stato: manca il canale
                let bare = body.split(separator: "(").first.map(String.init) ?? body
                if let o = outputs.first(where: { $0.id == bare }) {
                    let ex = o.channels >= 2 ? "\(o.id):1-2" : "\(o.id):1"
                    throw LBError("manca il canale dopo '\(o.id)': scrivi ad es. \(ex) (\(o.id) ha \(o.channels) canali)")
                }
                let ids = outputs.map { "\($0.id):1-\($0.channels)" }.joined(separator: ", ")
                throw LBError("'\(tok)' non è una destinazione: usa uscita:canali (\(ids))")
            }
            let (id, chans) = try RouteSpec.parseTarget(body)
            guard let oi = outputs.firstIndex(where: { $0.id == id }) else {
                let ids = outputs.map { $0.id }.joined(separator: ", ")
                throw LBError("uscita '\(id)' sconosciuta (disponibili: \(ids))")
            }
            if let bad = chans.first(where: { $0 > outputs[oi].channels }) {
                throw LBError("\(id) ha \(outputs[oi].channels) canali, non \(bad)")
            }
            result.append((oi, chans, gain))
        }
        return result
    }

    /// sum = true:  ogni canale d'origine va su tutti i canali di destinazione, a 1/N (N = canali d'origine):
    ///              la somma non supera mai il livello dei canali di partenza (-6 dB per 2, -12 dB per 4).
    /// sum = false: 1:1, in coppia (stessa lunghezza), uno → molti, o molti → uno in media.
    static func expand(src: [Int], dest: String, busChannels: Int, outputs: [OutputInfo], gainDb: Double = 0,
                       sum: Bool = false) throws -> [RouteKey: Float] {
        if let bad = src.first(where: { $0 < 1 || $0 > busChannels }) {
            throw LBError("il bus ha \(busChannels) canali, non \(bad)")
        }
        var r: [RouteKey: Float] = [:]
        for (oi, chans, g) in try parseDest(dest, outputs: outputs) {
            var lin = dbToLin(g + gainDb)
            guard lin > 0 else { continue }
            if sum {
                lin /= Float(src.count)
                for s in src { for d in chans { r[RouteKey(src: s - 1, out: oi, dst: d - 1)] = lin } }
                continue
            }
            // più canali su uno solo (es. stereo → b:5): media, non somma, per non andare in clip
            if chans.count == 1 && src.count > 1 { lin /= Float(src.count) }
            for (s, d) in try expandPairs(src: src, dst: chans) {
                r[RouteKey(src: s - 1, out: oi, dst: d - 1)] = lin
            }
        }
        return r
    }
}

/// Rotte raggruppate per proprietario: "config" (file), "manual" (OSC route/unroute)
/// e un proprietario per ogni device R4F Out, che scade se non si rifà vivo.
final class RouteBook {
    struct Owner {
        var routes: [RouteKey: Float]
        var src: String
        var dest: String
        var lastSeen: TimeInterval
        var expires: Bool
        var error: String?
    }

    private(set) var owners: [String: Owner] = [:]

    /// true se le rotte effettive sono cambiate
    @discardableResult
    func set(_ id: String, routes: [RouteKey: Float], src: String = "", dest: String = "",
             now: TimeInterval, expires: Bool, error: String? = nil) -> Bool {
        let old = owners[id]
        owners[id] = Owner(routes: routes, src: src, dest: dest, lastSeen: now, expires: expires, error: error)
        return old?.routes != routes
    }

    @discardableResult
    func edit(_ id: String, now: TimeInterval, _ body: (inout [RouteKey: Float]) -> Void) -> Bool {
        var o = owners[id] ?? Owner(routes: [:], src: "", dest: "", lastSeen: now, expires: false, error: nil)
        let before = o.routes
        body(&o.routes)
        o.lastSeen = now
        owners[id] = o
        return before != o.routes
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        guard let o = owners.removeValue(forKey: id) else { return false }
        return !o.routes.isEmpty
    }

    /// Rimuove i proprietari scaduti; true se le rotte effettive sono cambiate.
    @discardableResult
    func expire(now: TimeInterval, ttl: TimeInterval) -> Bool {
        var changed = false
        for (id, o) in owners where o.expires && now - o.lastSeen > ttl {
            owners.removeValue(forKey: id)
            if !o.routes.isEmpty { changed = true }
        }
        return changed
    }

    /// Unione di tutte le rotte; se due proprietari usano la stessa rotta vale il guadagno maggiore
    /// (un device duplicato non deve raddoppiare il livello).
    func merged() -> [RouteKey: Float] {
        var m: [RouteKey: Float] = [:]
        for o in owners.values {
            for (k, g) in o.routes { m[k] = max(m[k] ?? 0, g) }
        }
        return m
    }
}

/// Un'uscita che è lo stesso dispositivo del bus riscrive nel bus: è lecito (es. sommare canali e
/// rimandarli a un altro canale del bus), ma se il percorso torna al canale di partenza si crea un
/// anello di retroazione a guadagno pieno. Qui si trovano le rotte che chiudono un anello.
enum LoopGuard {
    /// - busOutputs: indici delle uscite che sono il dispositivo del bus.
    static func loopingKeys(_ routes: [RouteKey: Float], busOutputs: Set<Int>) -> Set<RouteKey> {
        let edges = routes.keys.filter { busOutputs.contains($0.out) }
        if edges.isEmpty { return [] }
        var next: [Int: [Int]] = [:]
        for e in edges { next[e.src, default: []].append(e.dst) }
        func reaches(_ from: Int, _ target: Int) -> Bool {
            var stack = [from], seen = Set<Int>()
            while let n = stack.popLast() {
                if n == target { return true }
                guard seen.insert(n).inserted else { continue }
                stack += next[n] ?? []
            }
            return false
        }
        // la rotta src → dst chiude un anello se da dst si torna a src
        return Set(edges.filter { reaches($0.dst, $0.src) })
    }
}
