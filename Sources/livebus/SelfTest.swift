import CLiveBus
import Foundation

/// Simulazione senza hardware: un bus e due uscite con clock che derivano,
/// buffer di dimensioni diverse e jitter di scheduling. Verifica assenza di
/// xrun, convergenza della correzione, qualità del ricampionamento,
/// fan-out, somma di canali e cambio di guadagno a caldo.
func runSelfTest(seconds: Double) -> Bool {
    var ok = runLogicTests()
    for ff in [true, false] {
        ok = simulate(feedForward: ff, seconds: seconds) && ok
    }
    print(ok ? "\nSELFTEST OK" : "\nSELFTEST FAILED")
    return ok
}

private struct SimOut { let nch: Int; let block: Int; let ppm: Double }

private func jitter(_ n: Int, _ salt: UInt64) -> Double {
    var x = UInt64(truncatingIfNeeded: n) &* 0x9E37_79B9_7F4A_7C15 ^ salt
    x ^= x >> 31; x &*= 0xBF58_476D_1CE4_E5B9; x ^= x >> 29
    return (Double(x % 10000) / 10000.0 - 0.5) * 0.0008 // ±0,4 ms
}

/// Minimi quadrati con sinusoidi a frequenza nota (cicli/campione): ampiezze e SNR del residuo.
private func fitSines(_ y: [Float], _ freqs: [Double]) -> (amps: [Double], snrDb: Double) {
    let m = freqs.count * 2
    var ata = [Double](repeating: 0, count: m * m), aty = [Double](repeating: 0, count: m)
    var basis = [Double](repeating: 0, count: m)
    for i in y.indices {
        for (k, f) in freqs.enumerated() {
            let ph = 2 * Double.pi * f * Double(i)
            basis[2 * k] = sin(ph); basis[2 * k + 1] = cos(ph)
        }
        for a in 0..<m {
            aty[a] += basis[a] * Double(y[i])
            for b in 0..<m { ata[a * m + b] += basis[a] * basis[b] }
        }
    }
    // Gauss-Jordan
    var A = ata, B = aty
    for c in 0..<m {
        var p = c
        for r in c..<m where abs(A[r * m + c]) > abs(A[p * m + c]) { p = r }
        if p != c { for k in 0..<m { A.swapAt(c * m + k, p * m + k) }; B.swapAt(c, p) }
        let d = A[c * m + c]
        for k in 0..<m { A[c * m + k] /= d }; B[c] /= d
        for r in 0..<m where r != c {
            let f = A[r * m + c]
            if f == 0 { continue }
            for k in 0..<m { A[r * m + k] -= f * A[c * m + k] }; B[r] -= f * B[c]
        }
    }
    var sig = 0.0, err = 0.0
    for i in y.indices {
        var model = 0.0
        for (k, f) in freqs.enumerated() {
            let ph = 2 * Double.pi * f * Double(i)
            model += B[2 * k] * sin(ph) + B[2 * k + 1] * cos(ph)
        }
        sig += model * model
        let e = Double(y[i]) - model
        err += e * e
    }
    let amps = freqs.indices.map { hypot(B[2 * $0], B[2 * $0 + 1]) }
    return (amps, 10 * log10(sig / max(err, 1e-30)))
}

private func simulate(feedForward ff: Bool, seconds: Double) -> Bool {
    let fs = 48000.0, hostFreq = 1e9
    let busCh = 4, inBlock = 512
    let outs = [SimOut(nch: 2, block: 256, ppm: 80), SimOut(nch: 3, block: 128, ppm: -120)]
    let freqs = [1000.0, 15000.0, 300.0, 5000.0]
    let amps: [Float] = [0.5, 0.5, 0.25, 0.25]

    print("\n— simulation \(Int(seconds)) s, feed-forward \(ff ? "on" : "off") —")
    let chans = outs.map { UInt32($0.nch) }
    guard let eng = lb_engine_create(UInt32(busCh), fs, hostFreq, UInt32(outs.count), chans, 4096, 16384) else {
        print("FAILED: engine creation"); return false
    }
    defer { lb_engine_destroy(eng) }
    for (i, o) in outs.enumerated() {
        lb_engine_config_output(eng, UInt32(i), 1.0, UInt32(inBlock + o.block + Int(LB_TAPS) + 128), ff ? 1 : 0, fs)
    }
    var routes = [
        lb_route(src: 0, out: 0, dst: 0, gain: 1), lb_route(src: 1, out: 0, dst: 1, gain: 1), // A: 1 kHz, 15 kHz
        lb_route(src: 0, out: 1, dst: 0, gain: 1), lb_route(src: 0, out: 1, dst: 1, gain: 1), // B: fan-out 1 kHz
        lb_route(src: 2, out: 1, dst: 2, gain: 0.5), lb_route(src: 3, out: 1, dst: 2, gain: 0.5), // B: somma
    ]
    lb_engine_set_routes(eng, &routes, UInt32(routes.count))

    var inBuf = [Float](repeating: 0, count: inBlock * busCh)
    var outBufs = outs.map { [Float](repeating: 0, count: $0.block * $0.nch) }
    let captureFrames = Int(fs)
    var captures = outs.map { o in [[Float]](repeating: [], count: o.nch) }
    var inK = 0
    var outM = [Int](repeating: 0, count: outs.count)
    var changedGain = false
    var maxAbsErr = [Double](repeating: 0, count: outs.count)

    while true {
        var next = Double(inK + 1) * Double(inBlock) / fs + jitter(inK, 1)
        var which = -1
        for i in outs.indices {
            let rate = fs * (1 + outs[i].ppm * 1e-6)
            let t = Double(outM[i] * outs[i].block) / rate + jitter(outM[i], UInt64(i + 7))
            if t < next { next = t; which = i }
        }
        if next > seconds { break }

        if !changedGain && next > seconds / 2 {
            routes[0].gain = 0.25 // -6 dB a caldo su A:1
            lb_engine_set_routes(eng, &routes, UInt32(routes.count))
            changedGain = true
        }
        if (inK & 255) == 0 { lb_engine_collect_garbage(eng) }

        if which < 0 {
            let base = inK * inBlock
            for f in 0..<inBlock {
                let n = Double(base + f)
                for c in 0..<busCh { inBuf[f * busCh + c] = amps[c] * Float(sin(2 * Double.pi * freqs[c] * n / fs)) }
            }
            let tFirst = Double(base) / fs * hostFreq
            inBuf.withUnsafeBufferPointer { p in
                let ch = (0..<busCh).map { lb_in_chan(ptr: p.baseAddress! + $0, stride: UInt32(busCh)) }
                lb_engine_process_input(eng, ch, UInt32(busCh), UInt32(inBlock), 1.0, tFirst)
            }
            inK += 1
        } else {
            let o = outs[which]
            let rate = fs * (1 + o.ppm * 1e-6)
            let hostOut = (Double(outM[which] * o.block) / rate + 2 * Double(o.block) / rate) * hostFreq
            let scalar = 1 / (1 + o.ppm * 1e-6)
            outBufs[which].withUnsafeMutableBufferPointer { p in
                let ch = (0..<o.nch).map { lb_out_chan(ptr: p.baseAddress! + $0, stride: UInt32(o.nch)) }
                lb_engine_process_output(eng, UInt32(which), ch, UInt32(o.nch), UInt32(o.block), scalar, hostOut)
            }
            var st = lb_output_stats()
            lb_engine_get_output_stats(eng, UInt32(which), &st)
            if next > 20 { maxAbsErr[which] = max(maxAbsErr[which], abs(st.error)) }
            if next > seconds - Double(captureFrames) / fs - 0.1 {
                for f in 0..<o.block { for c in 0..<o.nch { captures[which][c].append(outBufs[which][f * o.nch + c]) } }
            }
            outM[which] += 1
        }
    }

    var ok = true
    func verdict(_ cond: Bool, _ msg: String) {
        print((cond ? "  ok    " : "  FAILED  ") + msg)
        if !cond { ok = false }
    }

    for (i, o) in outs.enumerated() {
        var st = lb_output_stats()
        lb_engine_get_output_stats(eng, UInt32(i), &st)
        let expected = (1 / (1 + o.ppm * 1e-6) - 1) * 1e6
        let total = st.ppm_ff + st.ppm_pi
        let name = i == 0 ? "A" : "B"
        print("output \(name): real drift \(o.ppm) ppm, block \(o.block)")
        verdict(st.underruns == 0 && st.overruns == 0, "xrun \(st.underruns)/\(st.overruns)")
        verdict(abs(total - expected) < 2, String(format: "correction %+.2f ppm (expected %+.2f)", total, expected))
        verdict(maxAbsErr[i] < 64, String(format: "max fill error after 20 s: %.1f frames", maxAbsErr[i]))
    }

    // qualità: frequenze viste dall'uscita = f / (fs * (1 + ppm))
    let ya = captures[0].map { Array($0.suffix(captureFrames)) }
    let yb = captures[1].map { Array($0.suffix(captureFrames)) }
    let ka = 1 / (fs * (1 + outs[0].ppm * 1e-6)), kb = 1 / (fs * (1 + outs[1].ppm * 1e-6))
    let a0 = fitSines(ya[0], [freqs[0] * ka])
    let a1 = fitSines(ya[1], [freqs[1] * ka])
    let b0 = fitSines(yb[0], [freqs[0] * kb])
    let b2 = fitSines(yb[2], [freqs[2] * kb, freqs[3] * kb])
    verdict(a0.snrDb > 95, String(format: "A:1 1 kHz SNR %.1f dB", a0.snrDb))
    verdict(a1.snrDb > 95, String(format: "A:2 15 kHz SNR %.1f dB", a1.snrDb))
    verdict(b0.snrDb > 95, String(format: "B:1 1 kHz SNR %.1f dB", b0.snrDb))
    verdict(abs(a0.amps[0] - 0.125) < 0.002, String(format: "A:1 gain changed live: amplitude %.4f (expected 0.125)", a0.amps[0]))
    verdict(abs(a1.amps[0] - 0.5) < 0.005, String(format: "A:2 15 kHz response: amplitude %.4f (expected 0.5)", a1.amps[0]))
    verdict(ya[0].count == captureFrames && yb[0] == yb[1], "fan-out: B:1 and B:2 identical")
    verdict(abs(b2.amps[0] - 0.125) < 0.002 && abs(b2.amps[1] - 0.125) < 0.002,
            String(format: "sum on B:3: %.4f + %.4f (expected 0.125)", b2.amps[0], b2.amps[1]))
    verdict(b2.snrDb > 95, String(format: "B:3 sum SNR %.1f dB", b2.snrDb))
    return ok
}

/// Carico del motore a pieno regime: bus di `busCh` canali, `outs` uscite da `outCh`
/// canali tutte instradate, deriva diversa per ognuna. Misura il tempo CPU per secondo di audio.
func runBench(busCh: Int, outs nOut: Int, outCh: Int, block: Int) {
    let fs = 48000.0
    let chans = [UInt32](repeating: UInt32(outCh), count: nOut)
    guard let eng = lb_engine_create(UInt32(busCh), fs, 1e9, UInt32(nOut), chans, 4096, 16384) else { return }
    defer { lb_engine_destroy(eng) }
    var routes: [lb_route] = []
    for o in 0..<nOut {
        lb_engine_config_output(eng, UInt32(o), 1.0, UInt32(2 * block + Int(LB_TAPS) + 128), 1, fs)
        for c in 0..<outCh { routes.append(lb_route(src: UInt32((o * outCh + c) % busCh), out: UInt32(o), dst: UInt32(c), gain: 1)) }
    }
    lb_engine_set_routes(eng, &routes, UInt32(routes.count))
    var inBuf = [Float](repeating: 0, count: block * busCh)
    for i in inBuf.indices { inBuf[i] = Float(sin(Double(i) * 0.001)) * 0.3 }
    var outBuf = [Float](repeating: 0, count: block * outCh)
    let seconds = 10.0
    let cycles = Int(seconds * fs) / block
    let t0 = DispatchTime.now().uptimeNanoseconds
    inBuf.withUnsafeBufferPointer { ip in
        let ich = (0..<busCh).map { lb_in_chan(ptr: ip.baseAddress! + $0, stride: UInt32(busCh)) }
        outBuf.withUnsafeMutableBufferPointer { op in
            let och = (0..<outCh).map { lb_out_chan(ptr: op.baseAddress! + $0, stride: UInt32(outCh)) }
            for k in 0..<cycles {
                let t = Double(k * block) / fs * 1e9
                lb_engine_process_input(eng, ich, UInt32(busCh), UInt32(block), 1.0, t)
                for o in 0..<nOut {
                    let s = 1 / (1 + Double(o + 1) * 37e-6)
                    lb_engine_process_output(eng, UInt32(o), och, UInt32(outCh), UInt32(block), s, t + 2 * Double(block) / fs * 1e9)
                }
            }
        }
    }
    let cpu = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    var under: UInt64 = 0
    for o in 0..<nOut { var st = lb_output_stats(); lb_engine_get_output_stats(eng, UInt32(o), &st); under += st.underruns }
    print(String(format: "bus %d channels → %d outputs × %d channels (%d routes), block %d: %.1f%% of one core, xrun %llu",
                 busCh, nOut, outCh, routes.count, block, 100 * cpu / seconds, under))
}
