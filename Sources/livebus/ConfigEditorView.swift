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
                Text(kind == .bus ? "R4F BUS — dalla DAW alle schede audio" : "R4F BOX — da un programma all'altro").font(.headline)
                Text(m.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "nuova, non ancora salvata")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if kind == .bus {
                Button("Nuova dai dispositivi", action: actions.new)
                Button("Apri…", action: actions.open)
            } else {
                Button("Tutto 1:1", action: actions.new).help("Ogni uscita sul suo ingresso, come BlackHole")
            }
            Button("Ripristina", action: actions.revert).disabled(m.path == nil || !m.isDirty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: box

    private var boxSection: some View {
        section("R4F BOX", "Una scheda audio virtuale per passare l'audio tra programmi: un programma suona sulle "
                + "uscite di R4F BOX, un altro registra dai suoi ingressi. Qui decidi quale uscita arriva su quale "
                + "ingresso. La matrice lavora dentro il driver: nessuna latenza in più, e resta attiva anche ad app chiusa.") {
            HStack(spacing: 8) {
                if let d = m.device(m.bus) {
                    Label("\(d.name) installato — \(d.outputChannels) uscite, \(d.inputChannels) ingressi", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("R4F BOX non è installato (sudo driver/install.sh box)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button { m.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Aggiorna")
            }
            .font(.callout)
        }
    }

    // MARK: bus

    private var busSection: some View {
        section("Bus", "Il dispositivo che la DAW usa come uscita (Live, Logic, Reaper, Cubase, Pro Tools, Bitwig…). R4F lo legge e smista i canali.") {
            HStack {
                Picker("", selection: $m.bus) {
                    if m.bus.isEmpty { Text("— scegli —").tag("") }
                    if !m.bus.isEmpty && m.device(m.bus) == nil { Text("⚠︎ non collegato: \(m.bus)").tag(m.bus) }
                    ForEach(m.inputDevices, id: \.uid) { d in Text(m.deviceLabel(d, input: true)).tag(d.uid) }
                }
                .labelsHidden()
                .frame(maxWidth: 460)
                Button { m.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Aggiorna l'elenco dei dispositivi")
            }
        }
    }

    // MARK: uscite

    private var outputsSection: some View {
        section("Uscite", "Le schede su cui suonare. Il nome si dà da solo in base al dispositivo e si usa nelle rotte (es. mac:1-2) e, in Live, nel device R4F Out.") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    header("Nome (automatico)"); header("Dispositivo"); header("Canali"); header("Ritardo ms"); Color.clear.frame(width: 1, height: 1)
                }
                ForEach($m.outputs) { $o in
                    GridRow {
                        Text(o.name.isEmpty ? "—" : o.name)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 100, alignment: .leading)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                            .help("Nome automatico dal dispositivo: si usa nelle rotte, es. \(o.name):1-2")
                        Picker("", selection: $o.device) {
                            if o.device.isEmpty { Text("— scegli —").tag("") }
                            if !o.device.isEmpty && m.device(o.device) == nil { Text("⚠︎ non collegato: \(o.device)").tag(o.device) }
                            ForEach(m.outputDevices, id: \.uid) { d in Text(m.deviceLabel(d, input: false)).tag(d.uid) }
                        }
                        .labelsHidden().frame(width: 360)
                        Text(m.device(o.device).map { "\($0.outputChannels)" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                        TextField("0", text: $o.delayMs).frame(width: 70)
                        removeButton { m.removeOutput(o.id) }
                    }
                }
            }
            Button { m.addOutput() } label: { Label("Aggiungi uscita", systemImage: "plus") }
        }
        .onChange(of: m.outputs.map { $0.device }) { _ in m.syncNames() }
    }

    // MARK: rotte

    private var routesSection: some View {
        section("Rotte", kind == .box
                ? "Uscite della BOX (quello che i programmi mandano) → ingressi della BOX (quello che gli altri programmi ricevono). "
                    + "Destinazione: in:canali, es. in:5-6."
                : "Quali canali del bus vanno dove. Nella DAW manda ogni traccia o bus al canale d'uscita "
                    + "corrispondente di \(busName); qui decidi dove finisce ciascun canale.") {
            HStack {
                Picker("", selection: $routeMode) {
                    Text("Elenco").tag(0)
                    Text("Matrice").tag(1)
                    Text("Testo").tag(2)
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
                Text("Nessuna rotta: aggiungine una, usa un preset o la matrice.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        header("Nome"); header(kind == .box ? "Uscite BOX" : "Canali del bus"); Color.clear.frame(width: 1, height: 1)
                        header(kind == .box ? "Verso" : "Uscita")
                        header("Canali uscita"); header("Modo"); header("Guadagno dB"); header("Esito"); Color.clear.frame(width: 1, height: 1)
                    }
                    ForEach($m.routes) { $r in
                        GridRow {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(groupColor(r.name, in: m.groupNames)).frame(width: 6, height: 20)
                                TextField("senza nome", text: $r.name).frame(width: 110)
                            }
                            TextField("3-10", text: $r.from).frame(width: 80)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            if kind == .box {
                                Text("ingressi").foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
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
                                Text("Somma").tag(true)
                                Text("1:1").tag(false)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 118)
                            .help("Somma: ogni canale su tutte le uscite della rotta, a 1/N (nessun aumento di livello). 1:1: in coppia.")
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
                Button { m.addRoute() } label: { Label("Aggiungi rotta", systemImage: "plus") }
                    .disabled(m.outputs.isEmpty)
                Spacer()
            }
            Text("Canali: 5 · 1-8 · 1,3,5.  Somma: ogni canale va su tutte le uscite della rotta, ciascuno a 1/N (2 canali −6 dB, "
                 + "4 canali −12 dB), così il livello non sale mai.  1:1: in coppia (1→1, 2→2); uno solo a sinistra = lo stesso su "
                 + "tutte le uscite; più canali su uno solo = media." + (kind == .bus ? " Il bus 1-2 è di solito l'uscita principale della DAW." : ""))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: avanzate

    private var advancedSection: some View {
        DisclosureGroup("Avanzate", isExpanded: $showAdvanced) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Buffer")
                    Picker("", selection: $m.bufferFrames) {
                        ForEach(ConfigEditorModel.bufferChoices, id: \.self) { b in
                            Text(b == 0 ? "come il dispositivo" : "\(b) campioni").tag(b)
                        }
                    }
                    .labelsHidden().frame(width: 200)
                    Text("Meno = meno latenza, più carico.").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Allinea le schede")
                    Toggle("", isOn: $m.alignOutputs).labelsHidden()
                    Text("Ritarda le schede più veloci perché suonino insieme.").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Stima della deriva")
                    Toggle("", isOn: $m.feedForward).labelsHidden()
                    Text("Usa i dati di CoreAudio per seguire più in fretta i clock.").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Porta OSC")
                    TextField("7400", text: $m.oscPort).frame(width: 80)
                    Text("Per il device R4F Out in Live e per il controllo da altre app (default 7400).").font(.caption).foregroundStyle(.secondary)
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
                    Label("Configurazione valida", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                ForEach(issues.prefix(4)) { i in
                    Label(i.text, systemImage: i.blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(i.blocking ? Color.red : Color.orange)
                        .font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if issues.count > 4 { Text("…e altri \(issues.count - 4)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if kind == .bus { Button("Salva come…", action: actions.saveAs).disabled(!m.canSave) }
            Button("Salva e applica", action: actions.save)
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
            .buttonStyle(.borderless).help("Rimuovi")
    }
}
