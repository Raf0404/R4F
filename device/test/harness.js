// Test di livebus_out.js fuori da Max: Live API, Task, File, pattr e outlet simulati.
//   node device/test/harness.js
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SRC = fs.readFileSync(path.join(__dirname, "..", "livebus_out.js"), "utf8");
let failures = 0;
function check(cond, msg) {
    console.log((cond ? "  ok    " : "  FALLITO ") + msg);
    if (!cond) failures++;
}

// ---------------------------------------------------------------- Live simulato

function makeLive(opts) {
    const extName = opts.extName || "Ext. Out";
    const chans = [];
    if (opts.mono !== false) for (let i = 1; i <= 256; i++) chans.push({ display_name: String(i), identifier: 1000 + i });
    if (opts.pairs !== false) for (let i = 1; i < 256; i += 2) chans.push({ display_name: i + "/" + (i + 1), identifier: 2000 + i });
    const types = [{ display_name: "Master", identifier: 1 }, { display_name: "Sends Only", identifier: 3 }];
    if (opts.ext !== false) types.splice(1, 0, { display_name: extName, identifier: 2 });
    const masterChans = [{ display_name: "Post FX", identifier: 9 }];
    const tracks = (opts.tracks || []).map((t, i) => ({
        id: 100 + i, name: t.name || "T" + i,
        type: t.type ? types.find(x => x.display_name === t.type) : types[0],
        chan: null, init: t.chan,
    }));
    for (const t of tracks) {
        t.chan = t.init ? chans.find(c => c.display_name === t.init) : (t.type.identifier === 1 ? masterChans[0] : null);
    }
    const live = { tracks, types, chans, masterChans, observers: [], acceptForm: opts.acceptForm, sets: 0, notifyLock: false };
    live.byId = id => tracks.find(t => t.id === id);
    live.notify = (t, prop) => {
        for (const o of live.observers) if (o.track === t && o.property === prop) {
            live.notifyLock = true;
            try { o.cb(["x"]); } finally { live.notifyLock = false; }
        }
    };
    return live;
}

function makeLiveAPI(live, deviceTrackPath) {
    return class LiveAPI {
        constructor(a, b) {
            let cb = null, p = a;
            if (typeof a === "function") { cb = a; p = b; }
            this._cb = cb;
            this._resolve(p);
            this._property = null;
        }
        _resolve(p) {
            this.track = null; this.id = 0; this.type = ""; this.unquotedpath = p;
            if (p === "live_set") { this.id = 1; this.type = "Song"; return; }
            let m;
            if (p.startsWith("this_device")) {
                const ups = (p.match(/canonical_parent/g) || []).length;
                const chain = deviceTrackPath; // es. ["Chain","RackDevice","Track:0"]
                const node = chain[ups - 1];
                if (!node) { this.id = 0; return; }
                if (node.startsWith("Track:")) {
                    const idx = node.slice(6);
                    if (idx === "master") { this.type = "Track"; this.id = 50; this.unquotedpath = "live_set master_track"; return; }
                    this.track = live.tracks[Number(idx)]; this.type = "Track"; this.id = this.track.id;
                    this.unquotedpath = "live_set tracks " + idx; return;
                }
                this.type = node; this.id = 900 + ups; return;
            }
            if ((m = /^live_set tracks (\d+)$/.exec(p))) { this.track = live.tracks[Number(m[1])]; }
            else if ((m = /^id (\d+)$/.exec(p))) { this.track = live.byId(Number(m[1])); }
            if (this.track) { this.id = this.track.id; this.type = "Track"; }
        }
        set property(v) { this._property = v; if (this._cb) live.observers.push({ track: this.track, property: v, cb: this._cb }); }
        get property() { return this._property; }
        getcount(what) { return what === "tracks" ? live.tracks.length : 0; }
        get(prop) {
            const t = this.track;
            if (prop === "name") return [t.name];
            const wrap = (k, v) => [JSON.stringify({ [k]: v })];
            if (prop === "available_output_routing_types") return wrap(prop, live.types);
            if (prop === "output_routing_type") return wrap(prop, t.type);
            if (prop === "available_output_routing_channels") return wrap(prop, t.type.identifier === 2 ? live.chans : live.masterChans);
            if (prop === "output_routing_channel") return wrap(prop, t.chan);
            throw new Error("get " + prop);
        }
        set(prop, value) {
            if (live.notifyLock) throw new Error("Changes cannot be triggered by notifications");
            live.sets++;
            // accetta solo la forma configurata (simula l'incertezza sulla sintassi)
            let ident = null;
            if (live.acceptForm === "json-id" && typeof value === "string") {
                try { const o = JSON.parse(value); if (o && Object.keys(o).length === 1 && "identifier" in o) ident = o.identifier; } catch (e) {}
            } else if (live.acceptForm === "raw" && (typeof value === "number")) ident = value;
            if (ident === null) return; // ignorato in silenzio, come farebbe Live con un valore non valido
            const t = this.track;
            if (prop === "output_routing_type") {
                const ty = live.types.find(x => x.identifier === ident); if (!ty) return;
                t.type = ty; t.chan = ty.identifier === 2 ? live.chans[0] : live.masterChans[0];
                live.notify(t, "output_routing_type"); live.notify(t, "output_routing_channel");
            } else if (prop === "output_routing_channel") {
                const list = t.type.identifier === 2 ? live.chans : live.masterChans;
                const c = list.find(x => x.identifier === ident); if (!c) return;
                t.chan = c; live.notify(t, "output_routing_channel");
            }
        }
    };
}

// ---------------------------------------------------------------- istanza del device

function makeDevice(live, trackPath, stored, statusJson) {
    const sent = [], ui = { text: null, l1: "", l2: "" }, tasks = [], launches = [];
    const pattr = { v: stored === undefined ? 0 : stored, getvalueof() { return this.v; }, setvalueof(x) { this.v = x; } };
    const modeObj = { v: 0, getvalueof() { return this.v; } };
    const ctx = {
        LiveAPI: makeLiveAPI(live, trackPath),
        Task: class { constructor(fn, o) { this.fn = fn; tasks.push(this); this.pending = false; }
            repeat() { this.repeating = true; } schedule() { this.pending = true; } cancel() { this.repeating = false; this.pending = false; } },
        File: class { constructor(p) { this.isopen = statusJson.v !== null && p === "/tmp/livebus-status.json"; this.position = 0;
                this.data = statusJson.v || ""; this.eof = this.data.length; }
            readstring(n) { const s = this.data.slice(this.position, this.position + n); this.position += s.length; return s; } close() {} },
        outlet(n, ...a) {
            if (n === 0) sent.push(a);
            else if (n === 1) ui.text = a.slice(1).join(" ");
            else if (n === 2) ui.l1 = a.slice(1).join(" ");
            else if (n === 3) ui.l2 = a.slice(1).join(" ");
        },
        post() {}, setinletassist() {}, setoutletassist() {},
        messnamed(...a) { launches.push(a); },
        arrayfromargs(args) { return Array.prototype.slice.call(args); },
        patcher: { getnamed(n) { return n === "lbstate" ? pattr : n === "mode" ? modeObj : null; } },
        JSON, Math, Date, Number, String, encodeURIComponent, decodeURIComponent,
    };
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    const dev = {
        ctx, sent, ui, pattr, modeObj, tasks, launches,
        call(fn, ...a) { return ctx[fn].apply(ctx, a); },
        runTasks() { for (const t of tasks) if (t.pending) { t.pending = false; t.fn.call(ctx); } },
        tick() { for (const t of tasks) if (t.repeating) t.fn.call(ctx); },
        last() { return sent[sent.length - 1]; },
        owner() { return vm.runInContext("OWNER", ctx); },
        bus() { return vm.runInContext("bus.slice()", ctx); },
    };
    return dev;
}

function statusDoc(owners, extra) {
    return { v: JSON.stringify(Object.assign({ version: 1, session: 1, time: Date.now() / 1000,
        bus: { name: "R4F BUS", channels: 256 },
        outputs: [{ id: "a", channels: 64, running: true, underruns: 0 }, { id: "b", channels: 8, running: true, underruns: 0 }],
        owners: owners || {}, busPeaksDb: { "3": -12.2, "4": -14 } }, extra || {})) };
}

// ---------------------------------------------------------------- scenari

console.log("— 1. traccia sul Master, destinazioni salvate nel Set —");
{
    const live = makeLive({ acceptForm: "json-id", tracks: [{ name: "Voce" }, { name: "Synth", type: "Ext. Out", chan: "1/2" }] });
    const st = statusDoc();
    const d = makeDevice(live, ["Track:0"], encodeURIComponent("a:1-2 b:5@-6"), st);
    d.call("bang");
    const t = live.tracks[0];
    check(t.type.display_name === "Ext. Out" && t.chan.display_name === "3/4", "Audio To → Ext. Out 3/4 (1/2 occupato da Synth)");
    check(JSON.stringify(d.last()) === JSON.stringify(["/livebus/set", d.owner(), "3,4", "a:1-2 b:5@-6", 0]), "OSC /livebus/set con bus 3,4");
    check(d.ui.text === "a:1-2 b:5@-6", "textedit ripristinato dal pattr");
    check(/bus 3\/4 -> a:1-2/.test(d.ui.l1), "riga 1: " + d.ui.l1);
    check(/ok - outputs a:1-64 b:1-8\s+-12 dB/.test(d.ui.l2), "riga 2 mostra uscite e livello: " + d.ui.l2);
    check(vm.runInContext("setForm", d.ctx) === 0, "forma di set scoperta (JSON con identifier)");

    console.log("— 2. passaggio a mono —");
    d.call("mode", 1);
    check(t.chan.display_name === "3", "mono: canale 3 (1-2 riservati e occupati)");
    check(d.last()[2] === "3", "OSC con bus 3");

    console.log("— 3. l'utente sposta la traccia sul Master —");
    t.type = live.types[0]; t.chan = live.masterChans[0];
    live.notify(t, "output_routing_type");
    d.runTasks();
    check(d.last()[0] === "/livebus/release", "rotte rilasciate");
    check(/Reassign/.test(d.ui.l1), "invita a premere Riassegna: " + d.ui.l1);
    const setsBefore = live.sets;
    d.tick();
    check(live.sets === setsBefore, "il device non riprende il routing da solo");
    d.call("reassign");
    check(t.type.display_name === "Ext. Out" && t.chan.display_name === "3", "Riassegna ripristina Ext. Out 3");

    console.log("— 4. l'utente sceglie a mano un altro canale del bus —");
    t.chan = live.chans.find(c => c.display_name === "40");
    live.notify(t, "output_routing_channel");
    d.runTasks();
    check(d.last()[2] === "40", "il device segue la scelta manuale (bus 40)");

    console.log("— 5. destinazioni cancellate —");
    d.call("text");
    check(d.last()[0] === "/livebus/release" && d.pattr.v === "-", "release e pattr svuotato");
    const n = d.sent.length;
    d.tick(); d.tick();
    check(d.sent.length === n, "release inviato una sola volta");
    d.call("text", "b:1-2");
    check(d.last()[3] === "b:1-2" && decodeURIComponent(d.pattr.v) === "b:1-2", "nuove destinazioni inviate e salvate");
    d.call("text", "text", "a:3-4", "b:7@-3");
    check(d.last()[3] === "a:3-4 b:7@-3", "'text' doppio di textedit tolto");

    console.log("— 6. errore riportato da livebus —");
    st.v = statusDoc({ [d.owner()]: { error: "unknown output 'c' (available: a, b)" } }).v;
    d.tick();
    check(/error: unknown output 'c'/.test(d.ui.l2), "riga 2: " + d.ui.l2);
    st.v = statusDoc({}, { time: Date.now() / 1000 - 30 }).v;
    d.tick();
    check(/R4F not (running|responding)/.test(d.ui.l2), "stato vecchio → R4F non risponde: " + d.ui.l2);
    check(d.launches.length === 1 && d.launches[0].join(" ") === "max launchbrowser r4f://start",
          "R4F fermo → apre R4F via r4f://start");
    check(/starting R4F/.test(d.ui.l2), "riga 2: " + d.ui.l2);
    st.v = null;
    d.tick(); d.tick();
    check(d.launches.length === 1, "al massimo un tentativo ogni 30 s");
    vm.runInContext("lastLaunch -= 31", d.ctx);
    d.tick();
    check(d.launches.length === 2, "nuovo tentativo dopo 30 s");
    st.v = statusDoc().v;
    vm.runInContext("lastLaunch -= 31", d.ctx);
    d.tick();
    check(d.launches.length === 2 && /^ok/.test(d.ui.l2), "livebus attivo → nessun tentativo");

    st.v = statusDoc({}, { outputs: [{ id: "a", channels: 64, running: true, underruns: 0, clip: true }] }).v;
    d.tick();
    check(/a:1-64 CLIP/.test(d.ui.l2), "CLIP mostrato nel device: " + d.ui.l2);

    console.log("— 7. rimozione del device —");
    d.call("notifydeleted");
    check(d.last()[0] === "/livebus/release", "release alla rimozione");
}

console.log("— 8. traccia duplicata (stesso routing e stesse destinazioni copiati) —");
{
    const live = makeLive({ acceptForm: "raw", tracks: [{ type: "Ext. Out", chan: "5/6" }, { type: "Ext. Out", chan: "5/6" }] });
    const st = statusDoc();
    const a = makeDevice(live, ["Track:0"], encodeURIComponent("a:1-2"), st);
    a.call("bang");
    const b = makeDevice(live, ["Track:1"], encodeURIComponent("a:1-2"), st);
    b.call("bang");
    check(live.tracks[0].chan.display_name === "5/6", "originale resta su 5/6");
    check(live.tracks[1].chan.display_name === "3/4" && b.bus().length === 2, "la copia riceve un canale nuovo, saltando 1/2: " + live.tracks[1].chan.display_name);
    check(a.owner() !== b.owner(), "proprietari OSC diversi");
    check(vm.runInContext("setForm", b.ctx) === 2, "forma di set scoperta (identifier grezzo)");
}

console.log("— 9. device dentro un rack —");
{
    const live = makeLive({ acceptForm: "json-id", tracks: [{}, {}] });
    const d = makeDevice(live, ["Chain", "RackDevice", "Track:1"], encodeURIComponent("a:7"), statusDoc());
    d.call("bang");
    check(live.tracks[1].chan.display_name === "3/4", "trova la traccia risalendo chain e rack (1/2 riservati al Main)");
}

console.log("— 9b. traccia già messa a mano su 1/2 —");
{
    const live = makeLive({ acceptForm: "json-id", tracks: [{ type: "Ext. Out", chan: "1/2" }] });
    const d = makeDevice(live, ["Track:0"], encodeURIComponent("a:1-2"), statusDoc());
    d.call("bang");
    check(live.tracks[0].chan.display_name === "1/2" && d.last()[2] === "1,2", "una scelta manuale su 1/2 viene rispettata");
    d.call("reassign");
    check(live.tracks[0].chan.display_name === "3/4", "Riassegna la sposta fuori dai canali del Main");
}

console.log("— 10. sul Master, senza Ext. Out, solo coppie, nome localizzato —");
{
    const m = makeDevice(makeLive({ tracks: [{}] }), ["Track:master"], encodeURIComponent("a:1"), statusDoc());
    m.call("bang");
    check(/not on the Master/.test(m.ui.l1) && m.sent.length === 0, "Master: avviso, nessun OSC");

    const noExt = makeLive({ ext: false, acceptForm: "json-id", tracks: [{}] });
    const d = makeDevice(noExt, ["Track:0"], encodeURIComponent("a:1-2"), statusDoc());
    d.call("bang");
    check(/R4F BUS/.test(d.ui.l1) && d.last()[0] === "/livebus/release", "senza Ext. Out: avviso e nessuna rotta");

    const pairs = makeLive({ mono: false, acceptForm: "json-id", tracks: [{}] });
    const p = makeDevice(pairs, ["Track:0"], encodeURIComponent("b:3"), statusDoc());
    p.modeObj.v = 1;
    p.call("bang");
    check(pairs.tracks[0].chan.display_name === "3/4" && /only stereo pairs/.test(p.ui.l1), "mono richiesto ma solo coppie: usa 3/4 e lo dice");

    const ita = makeLive({ extName: "Est. Out", acceptForm: "json-id", tracks: [{}] });
    const i = makeDevice(ita, ["Track:0"], encodeURIComponent("a:1-2"), statusDoc());
    i.call("bang");
    check(ita.tracks[0].type.display_name === "Est. Out", "riconosce anche 'Est. Out'");
}

console.log(failures ? "\nHARNESS FALLITO (" + failures + ")" : "\nHARNESS OK");
process.exit(failures ? 1 : 0);
