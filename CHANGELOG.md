# Changelog

## 1.1.1 — installer e guida (2026-11-24)

- **Installer `R4F-1.1.1.pkg`** (`Scripts/build_installer.sh`): installa i driver R4F BUS e R4F BOX, l'app
  e il device per Live, poi apre R4F.
  - `preinstall` chiude R4F o LiveBus se aperte.
  - `postinstall` toglie le vecchie versioni LiveBus, riavvia CoreAudio, copia il device nella User Library
    dell'utente (solo se esiste) e apre l'app come utente.
  - Schermate di benvenuto, licenza e conclusione in italiano.
  - Bundle non spostabili dall'Installer (`<relocate/>` vuoto), richiede macOS 13 o successivo.
  - Non firmato con un certificato Developer ID: la guida spiega come aprirlo ("Apri comunque").
  - Verificato il contenuto del pacchetto espanso. L'installazione vera con il pacchetto non è ancora
    stata eseguita.
- File `VERSION` unico, usato da app e installer.
- **README riscritto come pagina iniziale**: download, installazione, primo avvio, collegamento delle DAW,
  configurazione di R4F BUS, matrice, testo e preset, R4F BOX, device per Live, problemi comuni,
  disinstallazione e sezione per sviluppatori.
- Schemi illustrativi `docs/schema-bus.svg` e `docs/schema-box.svg`: frecce disegnate come forme e
  non come marker SVG, così si vedono in qualsiasi visualizzatore.

## 1.1.1 — 2026-11-24

Preparazione alla pubblicazione su GitHub.

- `LICENSE`: testo ufficiale della GNU GPL v3.0 per tutto il progetto, obbligatoria perché i driver
  derivano da BlackHole.
- `NOTICE.md`: copyright, attribuzione a BlackHole (cosa è invariato e cosa è modificato), nota sul
  marchio BlackHole (non usato da R4F) e marchi di terze parti.
- `README.md` riscritto per GitHub: logo, sintesi in inglese, caratteristiche, screenshot, installazione
  dal sorgente, uso con le DAW e con R4F BOX, sintassi, configurazione, OSC e riga di comando, test,
  struttura, licenza.
- `Scripts/fetch_blackhole.sh`: scarica BlackHole v0.7.2 in `vendor/`, che non fa più parte del repository.
- `.gitignore`: escluse le cartelle di build, `vendor/` e `.DS_Store`.
- `docs/screenshots/`: elenco, matrice, testo, preset e R4F BOX, disegnati da `examples/demo.json`
  (nessun dato personale).

## 1.1.0 — 2026-11-19

- **Modo per rotta: Somma (default) o 1:1.** Richiesta: con `1-2 → mac:1-2` ogni canale deve andare su
  entrambe le uscite, sommati, senza alzare il livello.
  - **Somma**: ogni canale d'origine va su tutte le uscite della rotta, a 1/N (N = canali d'origine):
    −6 dB per 2, −12 dB per 4. Due canali identici a 0 dBFS danno 0 dBFS, quindi niente clip e niente
    aumento di volume. Da un solo canale è un fan-out a 0 dB.
  - **1:1**: il comportamento di prima (coppie, fan-out, molti su uno in media).
  - Le rotte nuove nascono in Somma. Le rotte salvate prima (senza `mode`) restano 1:1, così il suono
    non cambia da solo. Restano 1:1 anche i preset surround, l'1:1 della BOX, il "Main" della
    configurazione iniziale e le righe create dalla matrice.
  - Config: `"mode": "sum" | "pair"`, scritto sempre dall'editor.
  - Testo: `->` = somma, `=>` = 1:1.
  - Elenco: colonna **Modo**; l'esito indica "somma (−6 dB)".
  - Router e R4F BOX applicano il modo. La matrice dell'editor usa lo stesso calcolo del router.
- Il device R4F Out (Live) continua a mandare le tracce stereo in coppia.
- Test: somma 2→2, 4→3, fan-out, livello invariato con canali identici, compatibilità con le config
  precedenti, default delle rotte nuove, scrittura del modo, testo `=>`/`->` andata e ritorno, matrice.

## 1.0.1 — 2026-11-19

- **Logo R4F** come icona dell'app.
  - `assets/R4F-logo.jpg` è il logo originale. `Scripts/make_icon.swift` lo porta nella sagoma delle
    icone macOS (824 px su 1024, raggio 185, ombra) → `assets/R4F-icon-1024.png` → `assets/R4F.icns`.
  - Il logo riempie tutta la sagoma: il primo tentativo con un margine colorato mostrava una cornice più
    chiara, per una differenza di spazio colore.
  - `CFBundleIconFile` nell'app. Verificato: macOS restituisce la nuova icona per `/Applications/R4F.app`.
  - L'icona è copiata anche nei driver R4F BUS e R4F BOX (`R4F.icns`, già indicata da `kPlugIn_Icon`).
    Compare in Configurazione MIDI Audio dopo una reinstallazione dei driver.

## 1.0.0 — 2026-11-19

R4F: due schede virtuali da 256 canali che collaborano, un'unica app.

- **R4F BUS** (ex LiveBus): stesso driver, rinominato.
  - Nome "R4F BUS", UID `R4F BUS_UID`, bundle `local.r4f.bus`.
  - 256 canali: il driver a 260 è stato abbandonato perché il massimo utile è 256.
- **R4F BOX**, nuovo: scheda virtuale tra programmi con **matrice uscite → ingressi dentro il driver**.
  - Sorgente generato da `driver/r4fbox/make_source.py`: BlackHole più modifiche ancorate e verificate.
  - Proprietà personalizzata `r4fm`, una CFData di rotte `{UInt16 src, UInt16 dst, Float32 guadagno}`,
    dichiarata in `CustomPropertyInfoList`.
  - Doppio buffer con scambio atomico e attesa di due cicli audio prima di riusare lo slot.
  - Senza matrice vale 1:1, con copia diretta come BlackHole.
  - La matrice è salvata nella memoria del driver, quindi resta anche ad app chiusa.
- `driver/build.sh [bus|box|all]`.
- `install.sh` installa i driver R4F e toglie i vecchi LiveBus*; `uninstall.sh [bus|box|all]`.
- `drivertest --box`: proprietà, 1:1 di default, media, fan-out, canali muti, rilettura, salvataggio,
  ritorno all'1:1 bit-exact, costo (2,7% del ciclo con 512 rotte).
  - Corretto un bug del test: la macro `CHECK` valutava due volte la condizione.
- **R4F.app** (ex LiveBus.app): bundle `local.r4f.app`, URL `r4f://` e `livebus://`.
  - Cartella `~/Library/Application Support/R4F`, log `~/Library/Logs/R4F.log`.
  - Migrazione: copia la vecchia config. Appena R4F BUS compare (anche ad app aperta) sostituisce il bus
    "LiveBus…", con una copia di sicurezza.
  - Menu: stato di R4F BOX, "Configura R4F BUS…" (⌘,) e "Configura R4F BOX…".
  - Editor con le schede **R4F BUS / R4F BOX**. La BOX ha le stesse viste del BUS (Elenco, Matrice,
    Testo, Preset), destinazione `in:` e "Tutto 1:1"; salvataggio in `box.json` e invio al driver.
  - `R4FBox.swift`: impacchettamento della matrice, lettura e scrittura della proprietà, allineamento a
    ogni avvio e quando cambia l'elenco dei dispositivi.
- Device Max for Live **R4F Out** (`R4F Out.amxd`, cartella R4F). Lo script resta `livebus_out.js`, così
  i Set con il vecchio "LiveBus Out" continuano a funzionare. Apre l'app con `r4f://start`.
- Matrice dell'editor allineata in alto a sinistra quando è più piccola della finestra.
- `Scripts/build_app.sh`: rilevamento affidabile dell'app aperta e riapertura dopo l'aggiornamento.
- README riscritto per R4F.
- Corretto, emerso dalla prova sul driver installato: la matrice veniva passata a CoreAudio con
  `Unmanaged.passUnretained` senza tenere vivo il CFData, che Swift può liberare prima della chiamata
  (crash in uno script di prova). Ora c'è `withExtendedLifetime`.
- Verificato sul sistema: driver installati (il vecchio LiveBus 260ch è stato rimosso). L'app ha migrato
  da sola il bus a R4F BUS e il router è attivo. La matrice di R4F BOX è stata scritta e riletta
  attraverso CoreAudio (255 rotte, poi di nuovo 1:1).
- Nomi interni non cambiati: binario `livebus`, indirizzi OSC `/livebus/…`, file di stato
  `/tmp/livebus-status.json`.

## 0.6.1 — 2026-11-19

- **Nomi delle uscite automatici**, non più modificabili nell'editor.
  - Il nome deriva dal dispositivo: `mac` per l'uscita integrata, altrimenti la prima parola in
    minuscolo (`fireface`, `blackhole`), con un numero se due coincidono (`fireface2`).
  - Funzione unica (`DefaultConfig.outputBase/outputNames`) usata anche dalla configurazione iniziale.
  - Cambiando il dispositivo di un'uscita il nome si aggiorna e le rotte lo seguono, anche quando due
    dispositivi si scambiano.
  - Togliendo un'uscita le sue rotte restano segnalate (`⚠︎nome`) e non passano a un'altra uscita che
    prenderebbe quel nome.
  - Le configurazioni con nomi scritti a mano vengono portate ai nomi automatici all'apertura, con un
    avviso (vecchio → nuovo): vanno salvate, e vanno aggiornate le destinazioni nei device LiveBus Out.
  - Nel file JSON l'`id` resta; chi usa `livebus run` da terminale può ancora scriverlo a mano.
- Avvisi dell'editor su due righe.

## 0.6.0 — 2026-11-19

Tutte le DAW, matrice, testo, preset, nomi delle rotte.

- **Tutte le DAW**:
  - testi dell'app e dell'editor generici; guida per Live, Logic, Reaper, Cubase/Nuendo,
    Pro Tools e Bitwig nel README;
  - il device Max for Live resta un'aggiunta facoltativa per Live, e nel menu compare solo se ce
    ne sono di collegati;
  - **riavvio automatico quando cambia la frequenza di campionamento** del bus o di una scheda:
    le DAW spesso la impostano in base al progetto.
- **Nomi delle rotte**: campo `name` nella config, colonna Nome nell'elenco, rinomina dalla matrice.
  La rotta iniziale si chiama "Main".
- **Matrice** (`RouteMatrixView`, Canvas):
  - clic e trascinamento per collegare o scollegare; scelta della rotta per i nuovi collegamenti;
  - descrizione della casella sotto il puntatore, colori per rotta, caselle più chiare se il
    guadagno non è 0 dB, intervallo dei canali del bus regolabile.
- **Testo** (`RoutesTextView`): una rotta per riga, aggiornamento mentre si scrive, errori per riga
  (con un errore non cambia nulla).
- **Preset**:
  - stereo, LCR, quadrifonia, 5.0, 5.1, 7.1, 7.1.4, anello di 8, Ambisonics di 1°, 2° e 3° ordine;
  - ordine dei canali SMPTE/ITU o Film, scelto separatamente per la DAW e per gli altoparlanti;
  - propone il primo blocco libero del bus e un'uscita con abbastanza canali.
- Modello (`RouteMatrix.swift`):
  - coppie con guadagno effettivo (media inclusa) e ricompattazione in righe che conserva i
    guadagni entro 0,01 dB;
  - non crea mai righe "molti su uno" (cambierebbero il livello per la media);
  - tutti gli uno-a-uno di una rotta in una sola riga, anche in ordine sparso (`3-8 → 1,3,2,5-6,4`).
- **Anelli di retroazione** (`LoopGuard`). Trovato nella config dell'utente: un'uscita "blackhole"
  era in realtà LiveBus 256ch, con bus 1 → blackhole:1.
  - livebus scarta le rotte che chiudono un anello e lo segnala nel log, nel menu e con l'icona;
  - l'editor blocca il salvataggio;
  - "Aggiungi uscita" non propone più il dispositivo del bus;
  - nel menu dei dispositivi il bus è segnato "⚠︎ è il bus".
  - Verificato sull'app in esecuzione: la rotta è stata scartata al riavvio.
- `livebus render-editor --mode 0|1|2|3`: elenco, matrice, testo, finestra preset.
- Selftest: test per matrice (diagonale → una riga, andata e ritorno esatti, media), testo (andata e
  ritorno, sintassi, errori), preset (5.1 Film → SMPTE), rinomina, nomi salvati e anelli.

## 0.5.0 — 2026-11-19

Editor grafico della configurazione, dentro LiveBus.app.

- `ConfigEditorModel`: i campi restano testo come li scrive l'utente e sono validati riga per riga con
  lo stesso parser del router.
  - Una destinazione multipla nella config (`"ff:1-2 mac:1@-6"`) diventa più righe, con i guadagni sommati.
  - Al salvataggio scrive nomi leggibili (l'UID solo se il nome è duplicato) e conserva le opzioni che
    l'editor non mostra (`safetyFrames`, `statusFile`).
- `ConfigEditorView` (SwiftUI): sezioni Bus, Uscite, Rotte e Avanzate, con esito per riga e problemi
  in fondo, distinti in bloccanti e avvisi.
- `ConfigEditorWindow`: Nuova dai dispositivi, Apri, Salva e applica (⌘S), Salva come, Ripristina,
  conferma alla chiusura.
- Menu: **Configura…** (⌘,) e **Nuova configurazione…**. "Apri il file JSON" resta per chi vuole il testo.
- Dopo il salvataggio l'app si riavvia con la nuova config; con "Salva come" passa al nuovo file.
- `livebus render-editor <png> [--config f] [--dark]`: disegna l'editor in un'immagine senza aprire
  finestre, per controllarne l'aspetto. Controllato in tema chiaro e scuro.
- Selftest: 10 controlli sul modello dell'editor (caricamento e salvataggio senza perdite, stesso
  risultato audio, nomi duplicati, guadagno non valido, scheda scollegata = avviso, canale libero proposto).
- `Scripts/build_app.sh` riapre l'app se era aperta prima dell'aggiornamento.

## 0.4.1 — 2026-11-18

Dal test con due device in Live: una traccia stereo su `mac:1` arrivava a +5,8 dBFS. Le tracce erano
a −0,2 dBFS e L+R venivano sommati a pieno volume.

- Più canali su una sola destinazione (es. stereo → `b:5`) ora fanno la **media**, (L+R)/2, non la somma.
  Lo stesso vale nella config. Il fan-out (uno → molti) e le coppie restano a 0 dB.
- Avviso **CLIP** quando un'uscita supera 0 dBFS. Resta acceso 5 s e compare nel terminale (con un
  suggerimento), nel file di stato (`clip`), nel menu dell'app (icona di avviso) e nel device.

## 0.4.0 — 2026-11-18

LiveBus.app: si usa senza terminale.

- App nella barra dei menu (`Sources/livebus/MenuBarApp.swift`): stesso eseguibile di `livebus`, che passa
  in modalità app quando parte da un bundle `.app` (oppure con `livebus app`).
  - Il menu mostra stato, uscite, xrun, latenza e device collegati.
  - Comandi: Avvia/Ferma/Riavvia, modifica o scegli la config, dispositivi audio (clic = copia il nome),
    log, avvio all'accesso (SMAppService), Esci.
  - L'icona cambia con lo stato: in esecuzione, fermo, xrun, errore.
- `RouterController`:
  - se un dispositivo manca, riprova ogni 5 s;
  - si riavvia quando la config viene salvata (anche quando l'editor sostituisce il file) e quando
    cambia l'elenco dei dispositivi audio.
- Al primo avvio crea `~/Library/Application Support/LiveBus/config.json` dai dispositivi presenti
  (`DefaultConfig`): bus LiveBus, schede fisiche, uscita integrata = `mac`, Main su `mac:1-2`.
  `livebus default-config` la mostra.
- URL `livebus://start|stop|restart`.
- Il device LiveBus Out, se ha destinazioni e livebus non risponde, apre l'app con `;max launchbrowser livebus://start`
  (al massimo una volta ogni 30 s).
- `Scripts/build_app.sh`: bundle con `NSMicrophoneUsageDescription`, `LSUIElement`, schema URL; firma ad-hoc;
  installazione in /Applications e registrazione con LaunchServices.
- Log in `~/Library/Logs/LiveBus.log`.
- `OSCServer.stop()`, per i riavvii senza lasciare la porta occupata.
- Test: config di default (bus preferito, esclusione di virtuali e aggregati, nomi duplicati → UID) e
  avvio automatico dal device (harness).
- Verificato: build, firma e registrazione di `livebus://` → `/Applications/LiveBus.app`.
  Non ancora verificato: l'app avviata (permesso microfono, menu) e `launchbrowser` da Live con uno schema custom.

## 0.3.2 — 2026-11-18

Primo test in Live riuscito: il device ha impostato da solo Audio To su Ext. Out 3/4 (saltando 1/2),
livebus ha ricevuto le destinazioni e il device ha mostrato l'errore restituito da livebus.

- La riga di stato del device mostra le uscite nella sintassi da scrivere (`bh:1-64`, non `bh(64)`):
  l'utente aveva copiato `bh(64)` come destinazione.
- La porta OSC si apre prima dei dispositivi audio. Se è occupata (un altro livebus in esecuzione),
  l'errore lo dice e indica come fermarlo, senza aprire l'audio.
- Destinazione senza canale (`bh`, `bh(64)`): l'errore suggerisce `bh:1-2`. Un token sconosciuto elenca le uscite.

## 0.3.1 — 2026-11-18

- Device: i canali 1-2 del bus non vengono mai assegnati in automatico, perché ci escono il Main
  e il Cue di Live e la Live API non permette di leggerli. Una scelta manuale su 1/2 viene comunque rispettata.
- `examples/live-test.json`: bus 1-2 → altoparlanti del Mac (Main udibile), BlackHole 64ch come seconda uscita di prova.
- Messaggio chiaro se il file di configurazione non esiste, con l'elenco degli esempi.

## 0.3.0 — 2026-11-18

Fase 3: device Max for Live "LiveBus Out" (uno per traccia).

- `device/livebus_out.js` (js classico, ES5):
  - assegna un canale libero del bus e imposta Audio To via Live API;
  - prova le forme di `LiveAPI.set` e verifica rileggendo l'identifier, perché quella corretta per i dizionari non è documentata;
  - segue le modifiche manuali al routing, con le letture rimandate fuori dalle notifiche Live;
  - con le tracce duplicate il canale resta all'originale;
  - risale chain e rack fino alla traccia;
  - riconosce "Ext. Out" anche localizzato.
- `device/build_device.py`: genera `LiveBus Out.amxd` direttamente in formato binario, con attributi
  copiati da device reali. Verifica cavi e layout.
- `device/install_device.sh`: copia il device nella User Library e il `.js` in `~/Documents/Max 9/Library/LiveBus`.
- `device/test/harness.js`: 10 scenari con Live API, Task, File e pattr simulati.
- livebus:
  - rotte per proprietario (`RouteBook`: config, manuale, un proprietario per device), con scadenza dopo 6 s;
  - una rotta condivisa usa il guadagno maggiore invece di sommare;
  - OSC `/livebus/set` e `/livebus/release`;
  - sintassi `@dB` per destinazione;
  - file di stato `/tmp/livebus-status.json` scritto ogni secondo;
  - selftest con test della logica (rotte, proprietari, parser OSC).
- `/livebus/clear` ora azzera solo le rotte di config e manuali, non quelle dei device.
- Corretto, emerso dall'harness: `instanceof Array` non riconosce gli array creati in un altro
  contesto; sostituito da `Object.prototype.toString`.
- Non ancora verificato: il caricamento del device in Live e la forma di `LiveAPI.set` accettata davvero.

## 0.2.0 — 2026-11-18

Fase 2: driver virtuale.

- `vendor/BlackHole`: sorgente di BlackHole v0.7.2 (GPL-3), non modificato.
- `driver/build.sh [canali]`: compila "LiveBus <N>ch" con clang, senza Xcode.
  - Bundle universale arm64 + x86_64, firmato ad-hoc.
  - UUID della factory stabile per numero di canali (`factory-uuid-N.txt`).
  - Costanti di compilazione: volume disattivato nel percorso audio, niente suoni di sistema,
    frequenze 44,1–96 kHz.
  - Licenza e `SOURCE.txt` inclusi nel bundle.
- `driver/test/drivertest.c`: host AudioServerPlugIn finto che carica il driver nel processo e
  verifica factory, nome, canali, mirror nascosto, frequenze, loopback bit-exact su tutti i
  canali e costo per ciclo.
- `driver/install.sh` / `uninstall.sh`: installazione in `/Library/Audio/Plug-Ins/HAL`
  e riavvio di coreaudiod (sudo, a cura dell'utente).
- `livebus bench`: carico CPU del motore a pieno regime.
- L'avviso sul volume del bus viene saltato per i dispositivi LiveBus, dove il cursore non agisce.
- `examples/livebus-256.json`.
- Verificato (senza installare): 256 e 128 canali, loopback bit-exact fino all'ultimo canale,
  driver allo 0,14% del ciclo, router all'8,6% di un core con 256 canali verso 4 uscite.
  Non ancora verificato: il driver installato in coreaudiod e il numero di canali che Live accetta.

## 0.1.0 — 2026-11-18

Fase 1: motore della matrice.

- Motore real-time in C (`Sources/CLiveBus`):
  - IOProc del bus e un IOProc per ogni scheda di uscita.
  - Ring SPSC lock-free per ogni uscita.
  - Matrice di rotte sparsa, sostituita in modo atomico, con dissolvenza dei guadagni
    nel primo callback e liberazione differita delle tabelle vecchie.
  - Ricampionatore polifase: sinc con finestra di Kaiser, 64 tap × 256 fasi interpolate.
  - Correzione della deriva: feed-forward dai rate scalar di CoreAudio più PI sul
    riempimento "continuo", ricostruito con i timestamp host per evitare l'aliasing
    tra le dimensioni dei buffer.
- CLI Swift `livebus`: `devices`, `run <config.json>`, `tone`, `selftest`.
- Configurazione JSON: liste di canali, fan-out e somma, guadagno in dB, `bufferFrames`,
  allineamento della latenza tra schede, `delayMs` per uscita.
- Server OSC su 127.0.0.1: `/livebus/route`, `unroute`, `clear`, `load`, `routes`.
- Avviso all'avvio se il volume d'uscita del bus è abbassato. Sul Mac di sviluppo
  BlackHole era a −20 dB.
- Correzione trovata dal selftest: il riempimento misurato non contava la parte
  frazionaria del cursore di lettura. L'oscillazione di 1 frame che ne derivava
  portava l'SNR a 15 kHz a 59 dB; corretta, ora è oltre 100 dB.
- Verificato: in simulazione (±80/−120 ppm, 300 s) zero xrun, correzione esatta,
  SNR > 100 dB. Su hardware (BlackHole → altoparlanti del Mac e BlackHole stesso)
  zero xrun per 45 s, deriva +0,2 ppm, rotta cambiata via OSC a caldo.
