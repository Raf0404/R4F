// LiveBus Out — device Max for Live (js classico, ES5).
//
// Messo su una traccia, la manda su una o più uscite fisiche di LiveBus:
//   1. sceglie un canale libero del bus (coppia stereo o mono) e imposta
//      Audio To della traccia su Ext. Out → quel canale (Live API);
//   2. comunica a livebus le destinazioni via OSC (/livebus/set), ogni 2 s,
//      così livebus si riallinea da solo anche se viene riavviato;
//   3. legge /tmp/livebus-status.json per mostrare stato ed errori.
//
// Fader, pan e compensazione della latenza restano quelli di Live: il device
// non tocca l'audio (plugin~ → plugout~ diretto).

autowatch = 0;
inlets = 1;
outlets = 4;
setinletassist(0, "bang = init, text <dest>, mode <0|1>, reassign");
setoutletassist(0, "OSC verso udpsend");
setoutletassist(1, "verso textedit");
setoutletassist(2, "riga di stato 1");
setoutletassist(3, "riga di stato 2");

var STATUS_PATH = "/tmp/livebus-status.json";
var PUSH_MS = 2000;
var STALE_S = 5;
// Canali del bus mai assegnati in automatico: il Main (e il Cue) di Live escono qui,
// e la Live API non permette di leggere dove esce il Main.
var RESERVED = [1, 2];

var OWNER = "lbo-" + Math.floor(Math.random() * 2147483647).toString(36) + (new Date().getTime() % 1679616).toString(36);

var spec = "";          // destinazioni, es. "a:1-2 b:5@-6"
var mono = 0;           // 0 = coppia stereo, 1 = canale mono
var bus = [];           // canali del bus assegnati alla traccia, es. [17, 18]
var trackId = 0;
var trackName = "";
var started = false;
var setForm = -1;       // forma di LiveAPI.set accettata (scoperta a runtime)
var task = null;
var checkTask = null;
var obsType = null;
var obsChan = null;
var note = "";          // messaggio locale
var releasedSent = false;
var patcherRef = null;
var lbStatus = null;
var lastLaunch = 0;
var LAUNCH_EVERY_S = 30;

// ------------------------------------------------------------------ messaggi

function bang() { init(); }

function init() {
    patcherRef = this.patcher;
    restore();
    var m = getObj("mode");
    if (m) { var v = m.getvalueof(); mono = (isArray(v) ? Number(v[0]) : Number(v)) ? 1 : 0; }
    locate();
    if (!trackId) {
        note = "metti il device su una traccia (non sul Master)";
        show();
        return;
    }
    started = true;
    if (spec) claim(false); else adoptCurrent();
    observe();
    if (!task) {
        task = new Task(tick, this);
        task.interval = PUSH_MS;
        task.repeat();
    }
    readStatus();
    push();
    show();
}

// [textedit] → [prepend text] → qui. Se textedit antepone già "text", lo si toglie.
function text() {
    var a = arrayfromargs(arguments);
    if (a.length && String(a[0]) === "text") a.shift();
    spec = normalize(a.join(" "));
    save();
    if (started) {
        if (spec) claim(false);
        push();
    }
    show();
}

function mode(v) {
    var m = Number(v) ? 1 : 0;
    if (m === mono) return;
    mono = m;
    if (started && spec) { claim(true); push(); }
    show();
}

function reassign() {
    if (!started) return;
    claim(true);
    push();
    show();
}

function notifydeleted() {
    if (task) task.cancel();
    if (checkTask) checkTask.cancel();
    started = false;
    outlet(0, "/livebus/release", OWNER);
}

// ------------------------------------------------------------------ Live API

// gli array possono arrivare dal lato nativo di Max: instanceof Array non è affidabile
function isArray(v) {
    return Object.prototype.toString.call(v) === "[object Array]";
}

function first(v) {
    if (isArray(v)) return v.length === 1 ? v[0] : v.join(" ");
    return v;
}

// Le proprietà di routing arrivano come stringa JSON {"nome": valore}.
function dictProp(api, name) {
    var v = first(api.get(name));
    if (typeof v !== "string") return null;
    var o;
    try { o = JSON.parse(v); } catch (e) { return null; }
    if (o && o[name] !== undefined) return o[name];
    return o;
}

// La forma esatta che LiveAPI.set accetta per un dizionario non è documentata:
// si provano le varianti e si verifica rileggendo l'identifier.
var SET_FORMS = [
    function (api, p, e) { api.set(p, JSON.stringify({ identifier: e.identifier })); },
    function (api, p, e) { api.set(p, JSON.stringify(e)); },
    function (api, p, e) { api.set(p, e.identifier); },
    function (api, p, e) { api.set(p, e); }
];

function setDict(api, prop, entry) {
    var order = [];
    if (setForm >= 0) order.push(setForm);
    for (var i = 0; i < SET_FORMS.length; i++) if (i !== setForm) order.push(i);
    for (var k = 0; k < order.length; k++) {
        try { SET_FORMS[order[k]](api, prop, entry); } catch (err) { continue; }
        var cur = dictProp(api, prop);
        if (cur && String(cur.identifier) === String(entry.identifier)) {
            if (setForm !== order[k]) post("R4F Out: LiveAPI.set forma " + order[k] + "\n");
            setForm = order[k];
            return true;
        }
    }
    return false;
}

function isExt(entry) {
    return !!(entry && /^(ext|est|extern)/i.test(String(entry.display_name)));
}

// "17/18" → [17, 18], "5" → [5], "5 Fronte" → [5]
function chanNums(name) {
    var m = /^\s*(\d+)(?:\s*\/\s*(\d+))?/.exec(String(name));
    if (!m) return null;
    return m[2] ? [Number(m[1]), Number(m[2])] : [Number(m[1])];
}

function overlaps(nums, used) {
    for (var i = 0; i < nums.length; i++) if (used[nums[i]]) return true;
    return false;
}

function locate() {
    var path = "this_device";
    for (var i = 0; i < 16; i++) {
        path += " canonical_parent";
        var a = new LiveAPI(path);
        if (!a || Number(a.id) === 0) return;
        if (a.type === "Track") {
            var p = String(a.unquotedpath || a.path || "");
            if (p.indexOf("master_track") >= 0) return;
            trackId = Number(a.id);
            trackName = String(first(a.get("name")));
            return;
        }
    }
}

// Canali del bus già usati da altre tracce (Ext. Out).
// all: tutte le altre tracce; before: solo quelle che vengono prima nel Set
// (con una traccia duplicata il canale resta all'originale, la copia ne prende uno nuovo).
function usedChannels() {
    var all = {}, before = {}, seenSelf = false;
    var kinds = ["tracks", "return_tracks"];
    var set = new LiveAPI("live_set");
    for (var k = 0; k < kinds.length; k++) {
        var n = set.getcount(kinds[k]);
        for (var i = 0; i < n; i++) {
            var t = new LiveAPI("live_set " + kinds[k] + " " + i);
            if (Number(t.id) === trackId) { seenSelf = true; continue; }
            if (!isExt(dictProp(t, "output_routing_type"))) continue;
            var ch = dictProp(t, "output_routing_channel");
            var ns = ch ? chanNums(ch.display_name) : null;
            if (!ns) continue;
            for (var j = 0; j < ns.length; j++) {
                all[ns[j]] = true;
                if (!seenSelf) before[ns[j]] = true;
            }
        }
    }
    for (var r = 0; r < RESERVED.length; r++) all[RESERVED[r]] = true;
    return { all: all, before: before };
}

function choose(chans, want, used) {
    if (!isArray(chans)) return null;
    for (var i = 0; i < chans.length; i++) {
        var nums = chanNums(chans[i].display_name);
        if (nums && nums.length === want && !overlaps(nums, used)) return { entry: chans[i], nums: nums };
    }
    return null;
}

// Assegna alla traccia un canale libero del bus. Con force=false tiene quello
// attuale se è già sul bus, ha la larghezza giusta e nessun'altra traccia lo usa.
function claim(force) {
    var t = new LiveAPI("id " + trackId);
    var types = dictProp(t, "available_output_routing_types");
    if (!isArray(types)) { note = "routing della traccia non leggibile"; return; }
    var ext = null;
    for (var i = 0; i < types.length; i++) if (isExt(types[i])) { ext = types[i]; break; }
    if (!ext) {
        bus = [];
        note = "Ext. Out assente: in Preferenze > Audio scegli R4F BUS";
        return;
    }
    var want = mono ? 1 : 2;
    var used = usedChannels();
    var curT = dictProp(t, "output_routing_type");
    var curC = dictProp(t, "output_routing_channel");
    if (!force && isExt(curT) && curC) {
        var cur = chanNums(curC.display_name);
        if (cur && cur.length === want && !overlaps(cur, used.before)) { bus = cur; note = ""; return; }
    }
    if (!isExt(curT) && !setDict(t, "output_routing_type", ext)) {
        note = "impossibile impostare Audio To su Ext. Out";
        return;
    }
    var chans = dictProp(t, "available_output_routing_channels");
    var pick = choose(chans, want, used.all) || choose(chans, want === 2 ? 1 : 2, used.all);
    if (!pick) { bus = []; note = "nessun canale libero sul bus"; return; }
    if (!setDict(t, "output_routing_channel", pick.entry)) {
        note = "impossibile scegliere il canale " + pick.entry.display_name;
        return;
    }
    bus = pick.nums;
    if (pick.nums.length === want) note = "";
    else note = want === 2 ? "solo canali mono attivi in Live: L+R sommati" : "solo coppie stereo attive in Live";
}

// Senza destinazioni il device non tocca il routing: registra solo quello attuale.
function adoptCurrent() {
    var t = new LiveAPI("id " + trackId);
    var ty = dictProp(t, "output_routing_type");
    var ch = dictProp(t, "output_routing_channel");
    bus = (isExt(ty) && ch && chanNums(ch.display_name)) || [];
}

function observe() {
    obsType = new LiveAPI(onRoutingChange, "id " + trackId);
    obsType.property = "output_routing_type";
    obsChan = new LiveAPI(onRoutingChange, "id " + trackId);
    obsChan.property = "output_routing_channel";
}

// Dentro una notifica Live non accetta modifiche: si rimanda la lettura.
function onRoutingChange(args) {
    if (!started) return;
    if (!checkTask) checkTask = new Task(checkRouting, this);
    checkTask.schedule(50);
}

// Se l'utente cambia a mano Audio To, il device si adegua invece di combatterlo.
function checkRouting() {
    if (!started) return;
    var t = new LiveAPI("id " + trackId);
    var ty = dictProp(t, "output_routing_type");
    var ch = dictProp(t, "output_routing_channel");
    var n = (isExt(ty) && ch) ? chanNums(ch.display_name) : null;
    var nb = n || [];
    if (String(nb) === String(bus)) return;
    bus = nb;
    note = n ? "" : (spec ? "la traccia non va più sul bus: premi Riassegna" : "");
    push();
    show();
}

// ------------------------------------------------------------------ OSC e stato

function push() {
    if (!started) return;
    if (bus.length && spec) {
        outlet(0, "/livebus/set", OWNER, bus.join(","), spec, 0);
        releasedSent = false;
    } else if (!releasedSent) {
        outlet(0, "/livebus/release", OWNER);
        releasedSent = true;
    }
}

function tick() {
    push();
    readStatus();
    maybeLaunch();
    show();
}

function livebusAlive() {
    var now = new Date().getTime() / 1000;
    return !!(lbStatus && typeof lbStatus.time === "number" && now - lbStatus.time <= STALE_S);
}

// Se c'è qualcosa da instradare e livebus non risponde, apre LiveBus.app
// (URL livebus://start, registrato dall'app). Al massimo un tentativo ogni 30 s.
function maybeLaunch() {
    if (!started || !spec || livebusAlive()) return;
    var now = new Date().getTime() / 1000;
    if (now - lastLaunch < LAUNCH_EVERY_S) return;
    lastLaunch = now;
    messnamed("max", "launchbrowser", "r4f://start");
}

function readStatus() {
    lbStatus = null;
    var f = new File(STATUS_PATH, "read");
    if (!f.isopen) return;
    var s = "";
    for (var guard = 0; guard < 256 && f.position < f.eof; guard++) {
        var chunk = f.readstring(4096);
        if (!chunk) break;
        s += chunk;
    }
    f.close();
    try { lbStatus = JSON.parse(s); } catch (e) { lbStatus = null; }
}

function busLabel() {
    if (!bus.length) return "-";
    return bus.join("/");
}

function show() {
    var l1, l2;
    if (!started) l1 = note || "in attesa di Live";
    else if (note) l1 = note;
    else if (!spec) l1 = bus.length ? "bus " + busLabel() + ", nessuna destinazione" : "scrivi le destinazioni, es. a:1-2";
    else l1 = "bus " + busLabel() + " -> " + spec;

    var now = new Date().getTime() / 1000;
    if (!livebusAlive()) {
        l2 = lastLaunch ? "R4F non risponde: avvio R4F..." : "R4F non in esecuzione";
    } else {
        var me = lbStatus.owners && lbStatus.owners[OWNER];
        if (me && me.error) {
            l2 = "errore: " + me.error;
        } else {
            var outs = [];
            var list = lbStatus.outputs || [];
            for (var i = 0; i < list.length; i++) {
                var o = list[i];
                outs.push(o.id + ":1-" + o.channels + (o.running ? "" : " fermo") + (o.underruns ? " xrun " + o.underruns : "") + (o.clip ? " CLIP" : ""));
            }
            var lvl = "";
            if (bus.length && lbStatus.busPeaksDb) {
                var pk = -1000;
                for (var j = 0; j < bus.length; j++) {
                    var v = lbStatus.busPeaksDb[String(bus[j])];
                    if (typeof v === "number" && v > pk) pk = v;
                }
                lvl = pk > -1000 ? "  " + Math.round(pk) + " dB" : "  silenzio";
            }
            l2 = "ok - uscite " + outs.join(" ") + lvl;
        }
    }
    outlet(2, "set", l1);
    outlet(3, "set", l2);
}

// ------------------------------------------------------------------ salvataggio nel Set

function normalize(s) {
    return String(s).replace(/^\s+|\s+$/g, "").replace(/\s+/g, " ");
}

function getObj(name) {
    return patcherRef ? patcherRef.getnamed(name) : null;
}

// Le destinazioni vivono in un [pattr] di tipo blob salvato con il Set; codificate
// per non avere spazi né virgolette nel valore.
function save() {
    var p = getObj("lbstate");
    if (p) p.setvalueof(spec ? encodeURIComponent(spec) : "-");
}

function restore() {
    var p = getObj("lbstate");
    if (p) {
        var v = first(p.getvalueof());
        v = (v === undefined || v === null) ? "" : String(v);
        if (v && v !== "-" && v !== "0") {
            try { spec = normalize(decodeURIComponent(v)); } catch (e) { spec = normalize(v); }
        }
    }
    outlet(1, "set", spec);
}
