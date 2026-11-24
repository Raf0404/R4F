# Note legali e attribuzioni

**R4F** — Copyright © 2026 R4F

Questo programma è software libero: puoi ridistribuirlo e/o modificarlo secondo i termini della
GNU General Public License, versione 3, pubblicata dalla Free Software Foundation (vedi [`LICENSE`](LICENSE)).
È distribuito nella speranza che sia utile, ma **senza alcuna garanzia**, nemmeno implicita di
commerciabilità o di idoneità a uno scopo particolare.

## Codice di terze parti

### BlackHole

I driver **R4F BUS** e **R4F BOX** derivano dal sorgente di
[BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.2, © 2019–2026 Existential Audio Inc.,
distribuito sotto **GNU General Public License v3.0**.

- **R4F BUS** usa il sorgente di BlackHole senza modifiche; cambia solo le costanti di compilazione
  (nome, canali, frequenze, volume disattivato) in `driver/build.sh`.
- **R4F BOX** aggiunge una matrice di instradamento uscite → ingressi. Le modifiche sono generate da
  `driver/r4fbox/make_source.py` a partire dal sorgente originale, e il risultato è in
  `driver/r4fbox/R4FBox.c`.

Il sorgente di BlackHole non è incluso in questo repository: `Scripts/fetch_blackhole.sh` lo scarica
nella versione usata (tag `v0.7.2`) in `vendor/BlackHole`. Ogni driver compilato contiene la licenza
di BlackHole (`LICENSE-BlackHole.txt`) e una nota sulla provenienza (`SOURCE.txt`).

**Marchio.** Il nome, il logo e il marchio "BlackHole" appartengono a Existential Audio Inc. e non sono
concessi dalla GPL per versioni modificate. R4F non usa il nome né il logo di BlackHole per i suoi
prodotti: BlackHole è citato soltanto per indicare l'origine del codice, come richiesto dalla licenza.
R4F non è affiliato a Existential Audio Inc. né approvato da essa.

## Marchi

Ableton e Live sono marchi di Ableton AG. Max e Max for Live sono marchi di Cycling '74. Logic Pro e
macOS sono marchi di Apple Inc. Pro Tools è un marchio di Avid Technology. Gli altri nomi di prodotto
citati appartengono ai rispettivi proprietari e sono usati solo per indicare la compatibilità.
