import SwiftUI

struct ConfigEditorActions {
    var new: () -> Void = {}
    var open: () -> Void = {}
    var save: () -> Void = {}
    var saveAs: () -> Void = {}
    var revert: () -> Void = {}
}

enum EditorKind { case bus, box }

/// Editor grafico: R4F BUS (bus, uscite, rotte, avanzate) oppure R4F BOX (matrice uscite → ingressi).
struct ConfigEditorView: View {
    @ObservedObject var m: ConfigEditorModel
    var actions: ConfigEditorActions
    var kind: EditorKind = .bus
    @State private var showAdvanced = false
    @State private var routeMode = 0
    @State private var showPresets = false
    /// solo per il render di prova: vista iniziale delle rotte
    var initialRouteMode = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if kind == .bus {
                        busSection
                        outputsSection
                    } else {
                        boxSection
                    }
                    routesSection
                    if kind == .bus { advancedSection }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 600)
        .onAppear { routeMode = initialRouteMode }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: barra in alto

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .bus ? "R4F BUS — from your DAW to your audio interfaces" : "R4F BOX — from one app to another").font(.headline)
                Text(m.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "new, not saved yet")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if kind == .bus {
                Button("New from Devices", action: actions.new)
                Button("Open…", action: actions.open)
            } else {
                Button("All 1:1", action: actions.new).help("Each output to its own input")
            }
            Button("Revert", action: actions.revert).disabled(m.path == nil || !m.isDirty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: box

    private var boxSection: some View {
        section("R4F BOX", "A virtual audio device for passing audio between apps: one app plays into the "
                + "outputs of R4F BOX, another records from its inputs. Here you decide which output reaches which "
                + "input. The matrix runs inside the driver: no added latency, and it stays active even when the app is closed.") {
            HStack(spacing: 8) {
                if let d = m.device(m.bus) {
                    Label("\(d.name) installed — \(d.outputChannels) outputs, \(d.inputChannels) inputs", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("R4F BOX is not installed (sudo driver/install.sh box)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button { m.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            .font(.callout)
        }
    }

    // MARK: bus

    private var busSection: some View {
        section("Bus", "The device your DAW uses as its output (Live, Logic, Reaper, Cubase, Pro Tools, Bitwig…). R4F reads it and routes the channels.") {
            HStack {
                Picker("", selection: $m.bus) {
                    if m.bus.isEmpty { Text("— choose —").tag("") }
                    if !m.bus.isEmpty && m.device(m.bus) == nil { Text("⚠︎ not connected: \(m.bus)").tag(m.bus) }
                    ForEach(m.inputDevices, id: \.uid) { d in Text(m.deviceLabel(d, input: true)).tag(d.uid) }
                }
                .labelsHidden()
                .frame(maxWidth: 460)
                Button { m.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh the device list")
            }
        }
    }

    // MARK: uscite

    private var outputsSection: some View {
        section("Outputs", "The audio interfaces to play on. Each name is set automatically from the device and is used in routes (e.g. mac:1-2) and, in Live, in the R4F Out device.") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    header("Name (automatic)"); header("Device"); header("Channels"); header("Delay ms"); Color.clear.frame(width: 1, height: 1)
                }
                ForEach($m.outputs) { $o in
                    GridRow {
                        Text(o.name.isEmpty ? "—" : o.name)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 100, alignment: .leading)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                            .help("Automatic name from the device, used in routes, e.g. \(o.name):1-2")
                        Picker("", selection: $o.device) {
                            if o.device.isEmpty { Text("— choose —").tag("") }
                            if !o.device.isEmpty && m.device(o.device) == nil { Text("⚠︎ not connected: \(o.device)").tag(o.device) }
                            ForEach(m.outputDevices, id: \.uid) { d in Text(m.deviceLabel(d, input: false)).tag(d.uid) }
                        }
                        .labelsHidden().frame(width: 360)
                        Text(m.device(o.device).map { "\($0.outputChannels)" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                        TextField("0", text: $o.delayMs).frame(width: 70)
                        removeButton { m.removeOutput(o.id) }
                    }
                }
            }
            Button { m.addOutput() } label: { Label("Add Output", systemImage: "plus") }
        }
        .onChange(of: m.outputs.map { $0.device }) { _ in m.syncNames() }
    }

    // MARK: rotte

    private var routesSection: some View {
        section("Routes", kind == .box
                ? "BOX outputs (what apps send) → BOX inputs (what other apps receive). "
                    + "Destination: in:channels, e.g. in:5-6."
                : "Which bus channels go where. In your DAW, send each track or bus to the matching output channel "
                    + "of \(busName); here you decide where each channel ends up.") {
            HStack {
                Picker("", selection: $routeMode) {
                    Text("List").tag(0)
                    Text("Matrix").tag(1)
                    Text("Text").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
                Button { showPresets = true } label: { Label("Preset…", systemImage: "square.grid.3x2") }
                    .disabled(m.outputs.isEmpty)
            }
            switch routeMode {
            case 1: RouteMatrixView(m: m)
            case 2: RoutesTextView(m: m)
            default: routesList
            }
        }
        .sheet(isPresented: $showPresets) { PresetSheet(m: m, isPresented: $showPresets) }
    }

    private var busName: String { m.device(m.bus)?.name ?? "bus" }

    private var routesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if m.routes.isEmpty {
                Text("No routes: add one, use a preset or the matrix.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        header("Name"); header(kind == .box ? "BOX outputs" : "Bus channels"); Color.clear.frame(width: 1, height: 1)
                        header(kind == .box ? "To" : "Output")
                        header("Output channels"); header("Mode"); header("Gain dB"); header("Result"); Color.clear.frame(width: 1, height: 1)
                    }
                    ForEach($m.routes) { $r in
                        GridRow {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(groupColor(r.name, in: m.groupNames)).frame(width: 6, height: 20)
                                TextField("untitled", text: $r.name).frame(width: 110)
                            }
                            TextField("3-10", text: $r.from).frame(width: 80)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            if kind == .box {
                                Text("inputs").foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                            } else {
                                Picker("", selection: $r.out) {
                                    if r.out.isEmpty || !m.outputs.contains(where: { $0.name == r.out }) {
                                        Text(r.out.isEmpty ? "—" : "⚠︎ \(r.out)").tag(r.out)
                                    }
                                    ForEach(m.outputs) { o in Text(o.name).tag(o.name) }
                                }
                                .labelsHidden().frame(width: 100)
                            }
                            TextField("1-8", text: $r.channels).frame(width: 80)
                            Picker("", selection: $r.sum) {
                                Text("Sum").tag(true)
                                Text("1:1").tag(false)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 118)
                            .help("Sum: every channel to all the outputs of the route, at 1/N (no level increase). 1:1: in pairs.")
                            TextField("0", text: $r.gainDb).frame(width: 56)
                            let st = m.status(of: r)
                            Label(st.text, systemImage: st.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .font(.callout)
                                .foregroundStyle(st.ok ? Color.green : Color.red)
                                .lineLimit(2)
                                .frame(width: 190, alignment: .leading)
                            removeButton { m.routes.removeAll { $0.id == r.id } }
                        }
                    }
                }
            }
            HStack {
                Button { m.addRoute() } label: { Label("Add Route", systemImage: "plus") }
                    .disabled(m.outputs.isEmpty)
                Spacer()
            }
            Text("Channels: 5 · 1-8 · 1,3,5.  Sum: every channel goes to all the outputs of the route, each at 1/N (2 channels −6 dB, "
                 + "4 channels −12 dB), so the level never rises.  1:1: in pairs (1→1, 2→2); one channel on the left = the same on "
                 + "every output; several channels into one = average." + (kind == .bus ? " Bus 1-2 is usually the DAW's main output." : ""))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: avanzate

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Buffer")
                    Picker("", selection: $m.bufferFrames) {
                        ForEach(ConfigEditorModel.bufferChoices, id: \.self) { b in
                            Text(b == 0 ? "same as device" : "\(b) samples").tag(b)
                        }
                    }
                    .labelsHidden().frame(width: 200)
                    Text("Lower = less latency, more CPU load.").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Align interfaces")
                    Toggle("", isOn: $m.alignOutputs).labelsHidden()
                    Text("Delays the faster interfaces so that they all play together.").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Drift estimate")
                    Toggle("", isOn: $m.feedForward).labelsHidden()
                    Text("Uses CoreAudio data to follow the clocks faster.").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("OSC port")
                    TextField("7400", text: $m.oscPort).frame(width: 80)
                    Text("For the R4F Out device in Live and for control from other apps (default 7400).").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: piè di pagina

    private var footer: some View {
        let issues = m.issues
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if issues.isEmpty {
                    Label("Valid configuration", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                ForEach(issues.prefix(4)) { i in
                    Label(i.text, systemImage: i.blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(i.blocking ? Color.red : Color.orange)
                        .font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if issues.count > 4 { Text("…and \(issues.count - 4) more").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if kind == .bus { Button("Save As…", action: actions.saveAs).disabled(!m.canSave) }
            Button("Save and Apply", action: actions.save)
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!m.canSave)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: pezzi

    private func section<C: View>(_ title: String, _ help: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            Text(help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.borderless).help("Remove")
    }
}
