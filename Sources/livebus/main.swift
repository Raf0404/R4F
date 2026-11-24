import CLiveBus
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

private var keepAlive: [AnyObject] = []

private func onTerminate(_ body: @escaping () -> Void) {
    for s in [SIGINT, SIGTERM] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
        src.setEventHandler { body(); exit(0) }
        src.resume()
        keepAlive.append(src as AnyObject)
    }
}

private func usage() -> Never {
    print("""
    livebus — uscite multicanale per qualsiasi DAW (Live, Logic, Reaper, Cubase, Pro Tools, Bitwig…) via bus virtuale

    uso:
      livebus app                          icona nella barra dei menu (come LiveBus.app)
      livebus devices                      elenca i dispositivi audio
      livebus default-config               mostra la configurazione che l'app crea al primo avvio
      livebus run <config.json> [--status s]   avvia il router (Ctrl-C per fermare)
      livebus tone <dispositivo> [--channels 1-2] [--freq 440] [--level -18] [--cycle 0]
                                           tono di prova su un dispositivo (simula la DAW sul bus);
                                           --cycle N sposta il tono di canale ogni N secondi
      livebus selftest [--seconds 300]     simulazione di deriva e qualità, senza hardware
      livebus bench [--bus 256] [--outputs 4] [--channels 64] [--block 256]
                                           carico CPU del motore a pieno regime

    OSC (127.0.0.1, porta oscPort, default 7400; canali 1-based):
      /livebus/route <bus> <uscita> <canale> [dB]
      /livebus/unroute <bus> <uscita> <canale>
      /livebus/clear      /livebus/load <file.json>      /livebus/routes
    """)
    exit(2)
}

private func option(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

private func runRouter(_ args: [String]) {
    guard let path = args.first else { usage() }
    let interval = Double(option(args, "--status") ?? "2") ?? 2
    do {
        let cfg = try LiveBusConfig.load(path)
        let router = try Router(config: cfg)
        print(router.summary())
        // la porta OSC si apre PRIMA dell'audio: se è occupata non si tocca nessun dispositivo
        let port = cfg.oscPort ?? 7400
        var osc: OSCServer?
        if port > 0 { osc = try OSCServer(port: UInt16(port)) { router.handle($0) } }
        try router.start()
        print("avviato. Ctrl-C per fermare.")
        if let osc = osc {
            osc.start()
            keepAlive.append(osc)
            print("OSC in ascolto su 127.0.0.1:\(port)")
        }
        onTerminate { router.stop(); print("\nfermato.") }

        // ogni secondo: scadenza device, statistiche, file di stato; stampa ogni `interval` secondi
        let every = max(1, Int(interval.rounded()))
        var ticks = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            router.tick()
            ticks += 1
            if interval > 0, ticks % every == 0 { print(router.statusReport() + "\n") }
        }
        timer.resume()
        keepAlive.append(timer as AnyObject)
        keepAlive.append(router)
        dispatchMain()
    } catch {
        fputs("errore: \(error)\n", stderr)
        exit(1)
    }
}

private func runTone(_ args: [String]) {
    guard let query = args.first, !query.hasPrefix("--") else { usage() }
    do {
        let dev = try CoreAudioHelpers.find(query, in: CoreAudioHelpers.allDevices(), direction: .output)
        let list = try ChannelList.parse(option(args, "--channels") ?? "1-2")
        guard list.allSatisfy({ $0 <= dev.outputChannels }) else {
            throw LBError("\(dev.name) ha \(dev.outputChannels) canali di uscita")
        }
        let freq = Double(option(args, "--freq") ?? "440") ?? 440
        let level = Double(option(args, "--level") ?? "-18") ?? -18
        let cycle = Double(option(args, "--cycle") ?? "0") ?? 0
        let chans = list.map { UInt32($0 - 1) }
        guard let tone = lb_tone_create(dev.sampleRate, freq, dbToLin(level), chans, UInt32(chans.count), cycle) else {
            throw LBError("impossibile creare il tono")
        }
        var pid: AudioDeviceIOProcID?
        try check(lb_create_tone_proc(tone, dev.id, &pid), "IOProc tono")
        try check(AudioDeviceStart(dev.id, pid), "avvio tono")
        print("tono \(Int(freq)) Hz a \(Int(level)) dB su \(dev.name), canali \(list.map(String.init).joined(separator: ","))"
              + (cycle > 0 ? ", un canale ogni \(cycle) s" : "") + ". Ctrl-C per fermare.")
        onTerminate {
            AudioDeviceStop(dev.id, pid)
            AudioDeviceDestroyIOProcID(dev.id, pid!)
            lb_tone_destroy(tone)
        }
        if cycle > 0 {
            var last = UInt32.max
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 0.05)
            timer.setEventHandler {
                let c = lb_tone_current(tone)
                if c != last { last = c; print("→ canale \(list[Int(c)])") }
            }
            timer.resume()
            keepAlive.append(timer as AnyObject)
        }
        dispatchMain()
    } catch {
        fputs("errore: \(error)\n", stderr)
        exit(1)
    }
}

let argv = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
// lanciato come LiveBus.app (doppio clic, accesso, livebus://): modalità barra dei menu
if argv.isEmpty && Bundle.main.bundlePath.hasSuffix(".app") { runMenuBarApp() }
switch argv.first {
case "app": runMenuBarApp()
case "render-editor":
    // uso interno: disegna l'editor in un PNG per controllarne l'aspetto
    guard argv.count >= 2 else { usage() }
    renderEditor(to: argv[1], config: option(argv, "--config"), dark: argv.contains("--dark"),
                 mode: Int(option(argv, "--mode") ?? "0") ?? 0, box: argv.contains("--box"))
case "devices": listDevices()
case "default-config":
    do {
        let cfg = try DefaultConfig.make(devices: CoreAudioHelpers.allDevices())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try enc.encode(cfg), as: UTF8.self))
    } catch { fputs("errore: \(error)\n", stderr); exit(1) }
case "run": runRouter(Array(argv.dropFirst()))
case "tone": runTone(Array(argv.dropFirst()))
case "bench":
    let b = Int(option(argv, "--block") ?? "256") ?? 256
    runBench(busCh: Int(option(argv, "--bus") ?? "256") ?? 256, outs: Int(option(argv, "--outputs") ?? "4") ?? 4,
             outCh: Int(option(argv, "--channels") ?? "64") ?? 64, block: b)
case "selftest":
    let secs = Double(option(argv, "--seconds") ?? "300") ?? 300
    exit(runSelfTest(seconds: secs) ? 0 : 1)
default: usage()
}
