import SwiftUI

private let palette: [Color] = [
    Color(red: 0.20, green: 0.55, blue: 0.95), Color(red: 0.95, green: 0.55, blue: 0.15),
    Color(red: 0.30, green: 0.75, blue: 0.40), Color(red: 0.85, green: 0.30, blue: 0.55),
    Color(red: 0.60, green: 0.45, blue: 0.90), Color(red: 0.15, green: 0.70, blue: 0.75),
    Color(red: 0.85, green: 0.75, blue: 0.20), Color(red: 0.90, green: 0.35, blue: 0.30),
]

func groupColor(_ name: String, in names: [String]) -> Color {
    palette[(names.firstIndex(of: name) ?? 0) % palette.count]
}

// MARK: - Matrice

/// Righe = canali del bus, colonne = canali delle uscite. Clic o trascinamento per collegare/scollegare.
struct RouteMatrixView: View {
    @ObservedObject var m: ConfigEditorModel
    @State private var group = ""
    @State private var fromBus = 1
    @State private var toBus = 16
    @State private var hover = ""
    @State private var dragOn: Bool?
    @State private var visited = Set<ConfigEditorModel.Pair>()

    private static let newGroup = "\u{1}nuova"
    private let cell: CGFloat = 18, left: CGFloat = 48, top: CGFloat = 42

    private struct Col { let out: String; let ch: Int; let first: Bool }

    private var columns: [Col] {
        var cols: [Col] = []
        for o in m.outputs where !o.name.isEmpty {
            let used = m.routes.filter { $0.out == o.name }.compactMap { (try? ChannelList.parse($0.channels))?.max() }.max() ?? 2
            let n = m.device(o.device)?.outputChannels ?? used
            for c in 1...max(1, n) { cols.append(Col(out: o.name, ch: c, first: c == 1)) }
        }
        return cols
    }

    private var rows: [Int] { fromBus <= toBus ? Array(fromBus...toBus) : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            let cols = columns
            if cols.isEmpty {
                Text("Aggiungi prima un'uscita.").foregroundStyle(.secondary)
            } else {
                let w = left + CGFloat(cols.count) * cell + 8, h = top + CGFloat(rows.count) * cell + 8
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        // allineata in alto a sinistra anche quando è più piccola della finestra
                        grid(cols)
                            .frame(width: w, height: h)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                }
                .frame(height: min(h, 440))
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(hover.isEmpty ? "Clic su una casella per collegare o scollegare; trascina per farne tante (in diagonale = uno a uno)." : hover)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            legend
        }
        .onAppear(perform: initialRange)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text(m.isBox ? "Uscite della BOX da" : "Canali del bus da")
                TextField("", value: $fromBus, format: .number).frame(width: 48)
                Text("a")
                TextField("", value: $toBus, format: .number).frame(width: 48)
            }
            HStack(spacing: 6) {
                Text("Nuovi collegamenti in")
                Picker("", selection: $group) {
                    ForEach(m.groupNames, id: \.self) { n in Text(n.isEmpty ? "(senza nome)" : n).tag(n) }
                    Divider()
                    Text("Nuova rotta").tag(RouteMatrixView.newGroup)
                }
                .labelsHidden().frame(width: 170)
            }
        }
    }

    private func initialRange() {
        let maxSrc = m.connectionMap().keys.map { $0.src }.max() ?? 2
        let limit = m.busChannels ?? 256
        fromBus = 1
        toBus = min(limit, max(16, maxSrc + 4))
        group = m.groupNames.first ?? RouteMatrixView.newGroup
    }

    private func pair(at p: CGPoint, _ cols: [Col]) -> ConfigEditorModel.Pair? {
        let c = Int((p.x - left) / cell), r = Int((p.y - top) / cell)
        guard p.x >= left, p.y >= top, c < cols.count, r < rows.count else { return nil }
        return .init(src: rows[r], out: cols[c].out, dst: cols[c].ch)
    }

    private func targetGroup() -> String {
        if group == RouteMatrixView.newGroup || !m.groupNames.contains(group) {
            group = m.uniqueName("Rotta")
        }
        return group
    }

    private func grid(_ cols: [Col]) -> some View {
        let map = m.connectionMap()
        let names = m.groupNames
        let rowsNow = rows
        return Canvas { ctx, size in
            let line = Color.secondary.opacity(0.25)
            // intestazioni delle colonne
            for (i, c) in cols.enumerated() {
                let x = left + CGFloat(i) * cell
                if c.first {
                    ctx.draw(Text(m.isBox ? "ingressi della BOX" : c.out).font(.caption.weight(.semibold)), at: CGPoint(x: x + 2, y: 9), anchor: .leading)
                    var p = Path(); p.move(to: CGPoint(x: x, y: 2)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
                }
                ctx.draw(Text("\(c.ch)").font(.system(size: 8)).foregroundColor(.secondary),
                         at: CGPoint(x: x + cell / 2, y: top - 9))
            }
            // righe
            for (j, b) in rowsNow.enumerated() {
                let y = top + CGFloat(j) * cell
                ctx.draw(Text(m.isBox ? "out \(b)" : "bus \(b)").font(.system(size: 9)).foregroundColor(!m.isBox && b <= 2 ? .orange : .secondary),
                         at: CGPoint(x: left - 5, y: y + cell / 2), anchor: .trailing)
                for (i, c) in cols.enumerated() {
                    let r = CGRect(x: left + CGFloat(i) * cell, y: y, width: cell, height: cell).insetBy(dx: 1.5, dy: 1.5)
                    if let hit = map[.init(src: b, out: c.out, dst: c.ch)] {
                        let color = groupColor(m.routes[hit.row].name, in: names)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color.opacity(abs(hit.gainDb) < 0.01 ? 0.9 : 0.45)))
                    } else {
                        ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(line), lineWidth: 1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            guard let p = pair(at: v.location, cols) else { return }
            if dragOn == nil { dragOn = !m.isConnected(p) }
            guard visited.insert(p).inserted else { return }
            m.setConnection(p, on: dragOn!, group: dragOn! ? targetGroup() : "")
        }.onEnded { _ in
            dragOn = nil
            visited = []
        })
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                guard let p = pair(at: loc, cols) else { hover = ""; return }
                if let hit = map[p] {
                    let n = m.routes[hit.row].name
                    let g = abs(hit.gainDb) < 0.01 ? "0 dB" : String(format: "%+.1f dB", hit.gainDb)
                    hover = "bus \(p.src) → \(p.out):\(p.dst)  ·  \(n.isEmpty ? "(senza nome)" : n)  ·  \(g)  ·  clic per scollegare"
                } else {
                    let g = group == RouteMatrixView.newGroup ? "una nuova rotta" : "\"\(group)\""
                    hover = "bus \(p.src) → \(p.out):\(p.dst)  ·  libero  ·  clic per collegare in \(g)"
                }
            case .ended:
                hover = ""
            }
        }
    }

    private var legend: some View {
        let names = m.groupNames
        return VStack(alignment: .leading, spacing: 6) {
            if !names.isEmpty {
                Text("Rotte (rinomina qui o nell'elenco)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(names, id: \.self) { n in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(groupColor(n, in: names)).frame(width: 14, height: 14)
                    RenameField(name: n) { new in
                        m.renameGroup(n, to: new)
                        if group == n { group = new }
                    }
                    .frame(width: 180)
                    let k = m.routes.filter { $0.name == n }.compactMap { m.links(of: $0)?.count }.reduce(0, +)
                    Text(k == 1 ? "1 collegamento" : "\(k) collegamenti").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Campo che rinomina solo quando si preme Invio o si esce dal campo.
private struct RenameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("senza nome", text: $text)
            .onAppear { text = name }
            .onChange(of: name) { text = $0 }
            .onSubmit { if text != name { commit(text) } }
    }
}

// MARK: - Testo

struct RoutesTextView: View {
    @ObservedObject var m: ConfigEditorModel
    @State private var text = ""
    @State private var errors: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: text) { errors = m.applyText($0) }
            if errors.isEmpty {
                Label("Testo valido: le rotte sono aggiornate.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else {
                ForEach(errors.prefix(6), id: \.self) { e in
                    Label(e, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
                }
                Text("Finché c'è un errore le rotte restano quelle di prima.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Una rotta per riga:  Nome: canali -> uscita:canali  (->  somma,  =>  1:1)   ·   più uscite separate da spazio   ·   "
                 + "@dB per il guadagno   ·   # per i commenti.\nEsempi:   " + (m.isBox
                    ? "Zoom: 1-2 => in:5-6      Mix: 1-4 -> in:1-2 @-3      Copia: 3 -> in:3,10"
                    : "Main: 1-2 => mac:1-2      Mono: 3-4 -> a:1-2      Sub: 9 -> a:7-8 @-3"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { text = m.routesText(); errors = [] }
    }
}

// MARK: - Preset

struct PresetSheet: View {
    @ObservedObject var m: ConfigEditorModel
    @Binding var isPresented: Bool
    @State private var index = 4
    @State private var dawOrder = 0
    @State private var speakerOrder = 0
    @State private var busStart = 3
    @State private var out = ""
    @State private var outStart = 1
    @State private var name = ""

    private var preset: ConfigEditorModel.Preset { ConfigEditorModel.presets[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Aggiungi un preset").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Formato")
                    Picker("", selection: $index) {
                        ForEach(ConfigEditorModel.presets.indices, id: \.self) { i in Text(ConfigEditorModel.presets[i].title).tag(i) }
                    }
                    .labelsHidden().frame(width: 260)
                }
                if preset.hasOrders {
                    GridRow {
                        Text("Ordine nella DAW")
                        orderPicker($dawOrder)
                    }
                    GridRow {
                        Text("Ordine sugli altoparlanti")
                        orderPicker($speakerOrder)
                    }
                }
                GridRow {
                    Text(m.isBox ? "Uscite della BOX" : "Canali del bus")
                    HStack {
                        TextField("", value: $busStart, format: .number).frame(width: 56)
                        Text("– \(busStart + preset.count - 1)").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Uscita")
                    HStack {
                        Picker("", selection: $out) { ForEach(m.outputs) { o in Text(o.name).tag(o.name) } }
                            .labelsHidden().frame(width: 120)
                        Text("dal canale")
                        TextField("", value: $outStart, format: .number).frame(width: 56)
                        Text("– \(outStart + preset.count - 1)").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Nome della rotta")
                    TextField("", text: $name).frame(width: 200)
                }
            }
            preview
            if let pr = m.presetProblem(preset, busStart: busStart, out: out, outStart: outStart) {
                Label(pr.text, systemImage: pr.blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(pr.blocking ? Color.red : Color.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Annulla") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Aggiungi") {
                    let nm = name.trimmingCharacters(in: .whitespaces)
                    m.routes += m.presetRoutes(preset, dawOrder: dawOrder, speakerOrder: speakerOrder, busStart: busStart,
                                               out: out, outStart: outStart, name: nm.isEmpty ? preset.title : nm)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(m.presetProblem(preset, busStart: busStart, out: out, outStart: outStart)?.blocking ?? false)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { out = m.outputs.first?.name ?? ""; refresh() }
        .onChange(of: index) { _ in refresh() }
    }

    private func orderPicker(_ b: Binding<Int>) -> some View {
        Picker("", selection: b) {
            ForEach(preset.orders.indices, id: \.self) { i in
                Text("\(preset.orders[i].0):  \(preset.orders[i].1.joined(separator: " "))").tag(i)
            }
        }
        .labelsHidden().frame(width: 360)
    }

    private func refresh() {
        dawOrder = 0
        speakerOrder = 0
        // la prima uscita che ha abbastanza canali per il formato scelto
        if (m.channels(ofOutput: out) ?? 0) < preset.count,
           let fit = m.outputs.first(where: { (m.channels(ofOutput: $0.name) ?? 0) >= preset.count }) {
            out = fit.name
            outStart = 1
        }
        busStart = m.suggestBusStart(preset.count)
        let short = preset.title.components(separatedBy: " (").first ?? preset.title
        name = m.uniqueName(short)
    }

    private var preview: some View {
        let daw = preset.orders[min(dawOrder, preset.orders.count - 1)].1
        let spk = preset.orders[min(speakerOrder, preset.orders.count - 1)].1
        let items: [String] = daw.enumerated().map { i, label in
            let j = spk.firstIndex(of: label) ?? i
            return "bus \(busStart + i) \(label) → \(out):\(outStart + j)"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Collegamenti").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 3) {
                ForEach(items, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
            }
        }
    }
}
