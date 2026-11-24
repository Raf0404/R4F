import AppKit
import SwiftUI

/// Scheda mostrata nella finestra (condivisa con il menu per aprire direttamente BUS o BOX).
final class EditorTab: ObservableObject {
    @Published var kind: EditorKind = .bus
}

/// Contenitore: selettore R4F BUS / R4F BOX e l'editor corrispondente.
struct R4FEditorView: View {
    @ObservedObject var bus: ConfigEditorModel
    @ObservedObject var box: ConfigEditorModel
    @ObservedObject var tab: EditorTab
    var busActions: ConfigEditorActions
    var boxActions: ConfigEditorActions
    var initialRouteMode = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab.kind) {
                    Text("R4F BUS").tag(EditorKind.bus)
                    Text("R4F BOX").tag(EditorKind.box)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                Spacer()
                if bus.isDirty || box.isDirty {
                    Text("modifiche non salvate: " + [bus.isDirty ? "BUS" : nil, box.isDirty ? "BOX" : nil].compactMap { $0 }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
            if tab.kind == .bus {
                ConfigEditorView(m: bus, actions: busActions, kind: .bus, initialRouteMode: initialRouteMode)
            } else {
                ConfigEditorView(m: box, actions: boxActions, kind: .box, initialRouteMode: initialRouteMode)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Finestra di configurazione di R4F: pannelli Apri/Salva, conferma alla chiusura.
final class ConfigEditorWindow: NSObject, NSWindowDelegate {
    let model: ConfigEditorModel        // R4F BUS
    let boxModel: ConfigEditorModel     // R4F BOX
    let tab = EditorTab()
    private var window: NSWindow?
    /// R4F BUS salvato (percorso del file)
    var onSaved: (String) -> Void = { _ in }
    /// R4F BOX salvato e mandato al driver (messaggio di esito)
    var onBoxSaved: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

    init(model: ConfigEditorModel, boxModel: ConfigEditorModel) {
        self.model = model
        self.boxModel = boxModel
        super.init()
    }

    func show(_ kind: EditorKind? = nil) {
        if let k = kind { tab.kind = k }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "R4F — Configurazione"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: R4FEditorView(bus: model, box: boxModel, tab: tab,
                                                                  busActions: busActions(), boxActions: boxActions()))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func busActions() -> ConfigEditorActions {
        ConfigEditorActions(
            new: { [weak self] in self?.newFromDevices() },
            open: { [weak self] in self?.open() },
            save: { [weak self] in _ = self?.save() },
            saveAs: { [weak self] in _ = self?.saveAs() },
            revert: { [weak self] in self?.revert() }
        )
    }

    private func boxActions() -> ConfigEditorActions {
        ConfigEditorActions(
            new: { [weak self] in self?.boxModel.resetBoxIdentity() },
            open: {},
            save: { [weak self] in _ = self?.saveBox() },
            saveAs: {},
            revert: { [weak self] in
                guard let self = self else { return }
                self.boxModel.loadBox(R4FBox.load(), device: R4FBox.device())
            }
        )
    }

    // MARK: R4F BUS

    private func newFromDevices() {
        guard confirmDiscard(model, "Creare una configurazione nuova dai dispositivi collegati?") else { return }
        do { try model.loadDefaults() } catch { alert("Impossibile creare la configurazione", "\(error)") }
    }

    private func open() {
        guard confirmDiscard(model, "Aprire un'altra configurazione?") else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.directoryURL = URL(fileURLWithPath: MenuBarApp.supportDir)
        p.message = "Scegli una configurazione di R4F BUS"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try model.loadFile(url.path) } catch { alert("Configurazione non valida", "\(error)") }
    }

    private func revert() {
        guard let p = model.path else { return }
        do { try model.loadFile(p) } catch { alert("Impossibile rileggere il file", "\(error)") }
    }

    @discardableResult
    func save() -> Bool {
        guard let p = model.path else { return saveAs() }
        return write(p)
    }

    @discardableResult
    func saveAs() -> Bool {
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]
        p.directoryURL = URL(fileURLWithPath: (model.path as NSString?)?.deletingLastPathComponent ?? MenuBarApp.supportDir)
        p.nameFieldStringValue = (model.path as NSString?)?.lastPathComponent ?? "config.json"
        p.message = "Salva la configurazione (R4F BUS passerà a usare questo file)"
        guard p.runModal() == .OK, let url = p.url else { return false }
        return write(url.path)
    }

    private func write(_ p: String) -> Bool {
        guard model.canSave else { return false }
        do {
            try model.save(to: p)
            onSaved(p)
            return true
        } catch {
            alert("Salvataggio non riuscito", "\(error)")
            return false
        }
    }

    // MARK: R4F BOX

    @discardableResult
    func saveBox() -> Bool {
        guard boxModel.canSave else { return false }
        let cfg = boxModel.makeBoxConfig()
        do {
            try R4FBox.save(cfg)
            boxModel.markSavedExternally()
        } catch {
            alert("Salvataggio di R4F BOX non riuscito", "\(error)")
            return false
        }
        let msg = R4FBox.syncFromFile()
        onBoxSaved(msg)
        if R4FBox.device() == nil {
            alert("Matrice salvata", "R4F BOX non è installato: la matrice verrà applicata appena lo installi (sudo driver/install.sh box).")
        }
        return true
    }

    // MARK: chiusura

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let dirty = [model.isDirty ? "R4F BUS" : nil, boxModel.isDirty ? "R4F BOX" : nil].compactMap { $0 }
        guard !dirty.isEmpty else { return true }
        let a = NSAlert()
        a.messageText = "Salvare le modifiche a \(dirty.joined(separator: " e "))?"
        a.informativeText = "Se non salvi, R4F continua con la configurazione precedente."
        a.addButton(withTitle: "Salva e applica")
        a.addButton(withTitle: "Non salvare")
        a.addButton(withTitle: "Annulla")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            var ok = true
            if model.isDirty { ok = save() && ok }
            if boxModel.isDirty { ok = saveBox() && ok }
            return ok
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    // MARK: utilità

    private func confirmDiscard(_ m: ConfigEditorModel, _ question: String) -> Bool {
        guard m.isDirty else { return true }
        let a = NSAlert()
        a.messageText = question
        a.informativeText = "Le modifiche non salvate andranno perse."
        a.addButton(withTitle: "Continua")
        a.addButton(withTitle: "Annulla")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// Disegna l'editor in un PNG senza mostrare finestre (per controllarne l'aspetto).
/// mode: 0 elenco, 1 matrice, 2 testo, 3 finestra dei preset. box: scheda R4F BOX.
func renderEditor(to out: String, config: String?, dark: Bool, mode: Int = 0, box: Bool = false) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let model = ConfigEditorModel()
    let boxModel = ConfigEditorModel()
    do {
        if let c = config { try model.loadFile(c) } else { try model.loadDefaults() }
    } catch { fputs("errore: \(error)\n", stderr); exit(1) }
    boxModel.loadBox(R4FBox.load(), device: R4FBox.device())
    if box && boxModel.routes.count < 3 {
        // esempio: un programma su 1-2 verso 5-6, un mix di 4 canali su uno, 1:1 per il resto
        boxModel.routes = [
            .init(name: "Zoom", from: "1-2", out: R4FBox.inputsId, channels: "5-6", gainDb: ""),
            .init(name: "Mix", from: "3-6", out: R4FBox.inputsId, channels: "1", gainDb: "-3"),
            .init(name: "Resto 1:1", from: "7-32", out: R4FBox.inputsId, channels: "7-32", gainDb: ""),
        ]
    } else if !box && model.routes.count < 3 {
        if !model.outputs.contains(where: { $0.device.contains("BlackHole") }),
           let bh = model.outputDevices.first(where: { $0.name.contains("BlackHole") }) {
            model.outputs.append(.init(name: "", device: bh.uid, delayMs: ""))
            model.syncNames()
        }
        let target = model.outputs.last?.name ?? ""
        let p51 = ConfigEditorModel.presets.first { $0.id == "5.1" }!
        model.routes += model.presetRoutes(p51, dawOrder: 1, speakerOrder: 0, busStart: 3, out: target, outStart: 1, name: "5.1")
        model.routes.append(.init(name: "Voce", from: "9-10", out: target, channels: "9", gainDb: "-3"))
    }
    let tab = EditorTab()
    tab.kind = box ? .box : .bus
    let root: AnyView
    var size = NSSize(width: 960, height: 1000)
    if mode == 3 {
        root = AnyView(PresetSheet(m: box ? boxModel : model, isPresented: .constant(true)).background(Color(nsColor: .windowBackgroundColor)))
        size = NSSize(width: 560, height: 520)
    } else {
        root = AnyView(R4FEditorView(bus: model, box: boxModel, tab: tab, busActions: ConfigEditorActions(),
                                     boxActions: ConfigEditorActions(), initialRouteMode: mode))
    }
    let view = NSHostingView(rootView: root)
    view.frame = NSRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = view
    win.appearance = app.appearance
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: out)) } catch { fputs("errore: \(error)\n", stderr); exit(1) }
    print("ok: \(out)")
}
