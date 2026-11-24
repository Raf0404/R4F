import CoreAudio
import Foundation

struct LBError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

func osStatusString(_ st: OSStatus) -> String {
    let u = UInt32(bitPattern: st)
    let bytes = [UInt8((u >> 24) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) {
        return "'\(s)' (\(st))"
    }
    return "\(st)"
}

func check(_ st: OSStatus, _ what: String) throws {
    if st != noErr { throw LBError("\(what): \(osStatusString(st))") }
}

struct AudioDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double
    let bufferFrames: Int
    /// latenza di uscita dichiarata dal driver (latency + safety offset), in frame
    let outputLatency: Int
    /// kAudioDeviceTransportType… (built-in, USB, virtuale, aggregato…)
    let transport: UInt32

    var isVirtual: Bool { transport == kAudioDeviceTransportTypeVirtual }
    var isAggregate: Bool { transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

enum Direction { case input, output }

enum CoreAudioHelpers {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default def: T) -> T {
        var addr = address(sel, scope)
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        return st == noErr ? value : def
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func channels(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func device(_ id: AudioObjectID) -> AudioDevice {
        let lat: UInt32 = get(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, default: 0)
        let safety: UInt32 = get(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, default: 0)
        return AudioDevice(
            id: id,
            uid: string(id, kAudioDevicePropertyDeviceUID) ?? "?",
            name: string(id, kAudioObjectPropertyName) ?? "?",
            inputChannels: channels(id, kAudioObjectPropertyScopeInput),
            outputChannels: channels(id, kAudioObjectPropertyScopeOutput),
            sampleRate: get(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0)),
            bufferFrames: Int(get(id, kAudioDevicePropertyBufferFrameSize, default: UInt32(0))),
            outputLatency: Int(lat + safety),
            transport: get(id, kAudioDevicePropertyTransportType, default: UInt32(0))
        )
    }

    static func allDevices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(device(_:))
    }

    /// Cerca per UID esatto, poi nome esatto, poi sottostringa (senza maiuscole). Deve essere univoco.
    static func find(_ query: String, in devices: [AudioDevice], direction: Direction) throws -> AudioDevice {
        let usable = devices.filter { direction == .input ? $0.inputChannels > 0 : $0.outputChannels > 0 }
        let what = direction == .input ? "ingresso" : "uscita"
        if let d = usable.first(where: { $0.uid == query }) { return d }
        let exact = usable.filter { $0.name == query }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw LBError("più dispositivi di \(what) si chiamano '\(query)': usa l'UID (livebus devices)") }
        let partial = usable.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 {
            throw LBError("'\(query)' è ambiguo: \(partial.map { $0.name }.joined(separator: ", "))")
        }
        throw LBError("nessun dispositivo di \(what) corrisponde a '\(query)' (livebus devices per l'elenco)")
    }

    /// Volume d'uscita principale in dB se il dispositivo lo espone.
    static func outputVolumeDb(_ id: AudioObjectID) -> Float32? {
        var addr = address(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    static func setBufferFrames(_ id: AudioObjectID, _ frames: Int) -> Bool {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var v = UInt32(frames)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }
}

func listDevices() {
    let devices = CoreAudioHelpers.allDevices()
    print("ID    in  out   Hz      buf  nome  [uid]")
    for d in devices {
        print(String(format: "%-5u %3d %4d  %6.0f  %4d  ", d.id, d.inputChannels, d.outputChannels, d.sampleRate, d.bufferFrames)
              + "\(d.name)  [\(d.uid)]")
    }
}
