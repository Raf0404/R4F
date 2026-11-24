import CoreAudio
import Foundation

/// Rotte di R4F BOX salvate dall'app (con i nomi). Il driver tiene la sua copia senza nomi.
struct BoxConfig: Codable {
    var routes: [RouteSpec]
}

/// R4F BOX: scheda virtuale tra programmi. La matrice uscite → ingressi vive nel driver
/// (proprietà 'r4fm', CFData di rotte {UInt16 src, UInt16 dst, Float32 guadagno}, indici 0-based).
enum R4FBox {
    static let name = "R4F BOX"
    static let selector: AudioObjectPropertySelector = 0x7234_666D   // 'r4fm'
    /// nome dell'unica "uscita" nell'editor: gli ingressi della BOX
    static let inputsId = "in"
    static var path: String { (MenuBarApp.supportDir as NSString).appendingPathComponent("box.json") }

    static func device(_ devices: [AudioDevice] = CoreAudioHelpers.allDevices()) -> AudioDevice? {
        devices.first { $0.name == name && $0.outputChannels > 0 && $0.inputChannels > 0 }
    }

    static func identity(_ channels: Int = 256) -> [RouteSpec] {
        [RouteSpec(from: ChannelList(Array(1...channels)), to: "\(inputsId):1-\(channels)", gainDb: nil, name: "1:1", mode: "pair")]
    }

    // MARK: file

    static func load() -> BoxConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(BoxConfig.self, from: data)
    }

    static func save(_ cfg: BoxConfig) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(cfg).write(to: url, options: .atomic)
    }

    // MARK: matrice

    /// Collegamenti effettivi (0-based) delle rotte, con media e guadagni già calcolati.
    static func links(_ routes: [RouteSpec], channels: Int) throws -> [RouteKey: Float] {
        var all: [RouteKey: Float] = [:]
        let outs = [OutputInfo(id: inputsId, channels: channels)]
        for r in routes {
            let m = try RouteSpecParser.expand(src: r.from.channels, dest: r.to, busChannels: channels, outputs: outs,
                                               gainDb: r.gainDb ?? 0, sum: r.isSum)
            all.merge(m) { a, b in a + b }
        }
        return all
    }

    static func pack(_ links: [RouteKey: Float]) -> Data {
        var data = Data(capacity: links.count * 8)
        for (k, g) in links.sorted(by: { ($0.key.src, $0.key.dst) < ($1.key.src, $1.key.dst) }) {
            var s = UInt16(k.src).littleEndian, d = UInt16(k.dst).littleEndian, b = g.bitPattern.littleEndian
            withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &d) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpack(_ data: Data) -> [RouteKey: Float] {
        var out: [RouteKey: Float] = [:]
        let n = data.count / 8
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let s = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt16.self)))
                let d = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8 + 2, as: UInt16.self)))
                let g = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt32.self)))
                out[RouteKey(src: s, out: 0, dst: d)] = g
            }
        }
        return out
    }

    /// Manda la matrice al driver (che la applica subito e la ricorda anche ad app chiusa).
    static func push(_ links: [RouteKey: Float], to dev: AudioObjectID) throws {
        let cf = pack(links) as CFData
        var addr = CoreAudioHelpers.address(selector)
        // il CFData deve restare vivo per tutta la chiamata: con passUnretained Swift potrebbe liberarlo prima
        let st: OSStatus = withExtendedLifetime(cf) {
            var ref = Unmanaged.passUnretained(cf)
            return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFData>>.size), &ref)
        }
        try check(st, "matrice di R4F BOX")
    }

    static func read(from dev: AudioObjectID) -> [RouteKey: Float]? {
        var addr = CoreAudioHelpers.address(selector)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var ref: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ref) == noErr, let r = ref else { return nil }
        guard let data = r.takeRetainedValue() as? Data else { return nil }
        return unpack(data)
    }

    /// All'avvio dell'app e quando cambiano i dispositivi: il driver si allinea a box.json.
    @discardableResult
    static func syncFromFile() -> String {
        guard let dev = device() else { return "R4F BOX non installato" }
        guard let cfg = load() else { return "R4F BOX: matrice del driver (\(describe(dev)))" }
        do {
            try push(try links(cfg.routes, channels: dev.outputChannels), to: dev.id)
            return "R4F BOX: \(describe(dev))"
        } catch {
            return "R4F BOX: errore — \(error)"
        }
    }

    /// "1:1 su 256 canali" oppure "12 collegamenti".
    static func describe(_ dev: AudioDevice) -> String {
        guard let m = read(from: dev.id) else { return "matrice non leggibile" }
        let n = dev.outputChannels
        let isIdentity = m.count == n && m.allSatisfy { $0.key.src == $0.key.dst && $0.value == 1 }
        if isIdentity { return "1:1 su \(n) canali" }
        return m.isEmpty ? "tutto muto" : (m.count == 1 ? "1 collegamento" : "\(m.count) collegamenti")
    }
}
