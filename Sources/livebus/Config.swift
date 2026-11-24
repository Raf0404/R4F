import Foundation

/// Lista di canali 1-based: 5, "1-8", "1,3,5", "1-4,9-12".
struct ChannelList: Codable {
    let channels: [Int]

    init(_ channels: [Int]) { self.channels = channels }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            channels = [i]
        } else {
            channels = try ChannelList.parse(try c.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(ChannelList.format(channels))
    }

    /// [1,2,3,4,9] → "1-4,9"
    static func format(_ list: [Int]) -> String {
        var parts: [String] = []
        var i = 0
        while i < list.count {
            var j = i
            while j + 1 < list.count && list[j + 1] == list[j] + 1 { j += 1 }
            if j - i >= 1 { parts.append("\(list[i])-\(list[j])") } else { parts.append("\(list[i])") }
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    static func parse(_ s: String) throws -> [Int] {
        var out: [Int] = []
        for part in s.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            let ends = p.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            if ends.count == 1, let v = Int(ends[0]), v >= 1 {
                out.append(v)
            } else if ends.count == 2, let a = Int(ends[0]), let b = Int(ends[1]), a >= 1, b >= 1 {
                out.append(contentsOf: a <= b ? Array(a...b) : Array((b...a).reversed()))
            } else {
                throw LBError("lista di canali non valida: '\(s)'")
            }
        }
        if out.isEmpty { throw LBError("lista di canali vuota") }
        return out
    }
}

struct OutputSpec: Codable {
    /// nome breve usato nelle rotte, es. "rme"
    var id: String
    /// nome o UID del dispositivo CoreAudio
    var device: String
    /// ritardo aggiuntivo per allineare a mano (ms)
    var delayMs: Double?
}

struct RouteSpec: Codable {
    var from: ChannelList
    /// "idUscita:canali", es. "rme:1-8"
    var to: String
    var gainDb: Double?
    /// nome libero della rotta (es. "Fronte", "5.1"), solo descrittivo
    var name: String? = nil
    /// "sum": ogni canale su tutte le destinazioni, a 1/N; "pair" o assente: 1:1 (comportamento storico)
    var mode: String? = nil

    var isSum: Bool { mode == "sum" }

    static func parseTarget(_ s: String) throws -> (String, [Int]) {
        guard let colon = s.lastIndex(of: ":") else { throw LBError("destinazione '\(s)': usa id:canali, es. rme:1-8") }
        let id = String(s[..<colon])
        let chans = try ChannelList.parse(String(s[s.index(after: colon)...]))
        return (id, chans)
    }
}

struct LiveBusConfig: Codable {
    /// dispositivo su cui scrive Live (es. "BlackHole 64ch")
    var bus: String
    var outputs: [OutputSpec]
    var routes: [RouteSpec]?
    /// dimensione buffer da chiedere ai dispositivi per questo processo
    var bufferFrames: Int?
    /// margine del ring oltre i buffer (frame)
    var safetyFrames: Int?
    /// usa i rate scalar di CoreAudio come stima iniziale della deriva
    var feedForward: Bool?
    /// allinea la latenza di tutte le uscite a quella più lenta
    var alignOutputs: Bool?
    /// porta OSC su 127.0.0.1 (0 = disattivato)
    var oscPort: Int?
    /// file di stato letto dai device Max for Live ("" = disattivato)
    var statusFile: String?

    static func load(_ path: String) throws -> LiveBusConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let examples = (try? FileManager.default.contentsOfDirectory(atPath: "examples"))?
                .filter { $0.hasSuffix(".json") }.sorted().map { "examples/" + $0 } ?? []
            throw LBError("file di configurazione non trovato: \(path)"
                + (examples.isEmpty ? "" : "\n  esempi disponibili: " + examples.joined(separator: ", ")))
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(LiveBusConfig.self, from: data)
        } catch let e as DecodingError {
            throw LBError("configurazione non valida (\(path)): \(describe(e))")
        }
    }

    private static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, let ctx): return "manca '\(k.stringValue)' in \(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "\(ctx.codingPath.map { $0.stringValue }.joined(separator: ".")): \(ctx.debugDescription)"
        @unknown default: return "\(e)"
        }
    }
}

/// Uno-a-uno se le liste hanno la stessa lunghezza, uno-a-molti o molti-a-uno se un lato ha un solo canale.
func expandPairs(src: [Int], dst: [Int]) throws -> [(Int, Int)] {
    if src.count == dst.count { return Array(zip(src, dst)) }
    if src.count == 1 { return dst.map { (src[0], $0) } }
    if dst.count == 1 { return src.map { ($0, dst[0]) } }
    throw LBError("rotta \(src.count)→\(dst.count) canali: le liste devono avere la stessa lunghezza, oppure una deve avere un solo canale")
}

func dbToLin(_ db: Double) -> Float {
    db <= -144 ? 0 : Float(pow(10.0, db / 20.0))
}

func linToDbString(_ v: Float) -> String {
    v <= 0 ? "-inf" : String(format: "%.1f", 20 * log10(Double(v)))
}
