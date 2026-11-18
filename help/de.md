# Tapedeck

Tapedeck nimmt auf, was dein Mac abspielt – einen Browser-Tab, einen Videoanruf, einen Player – und speichert es als WAV-Datei mit 48 kHz und 24 bit. Vor dem Speichern kannst du die Aufnahme schneiden, andere Audiodateien anfügen und die Teile neu ordnen.

![Das Aufnahmefenster: Schriftzug, Zählwerk und die Tasten aufnahme und stop](aufnahme.png)

## Aufnehmen

- Drück **aufnahme** (oder die Leertaste). Die Taste bleibt gedrückt und das Zählwerk läuft, solange Tapedeck aufnimmt.
- Drück **stop** (oder die Leertaste). Das Schnittfenster öffnet sich.
- Tapedeck nimmt alles auf, was über den Mac abgespielt wird. Eigene Töne von Tapedeck sind nicht dabei. Es braucht keinen Treiber und ändert nichts an deiner Tonausgabe.
- Bis du sicherst, liegt die Aufnahme nur in einem temporären Ordner.

## Das Recht zur Aufnahme

Beim ersten Mal fragt macOS nach dem Recht zur **Bildschirm- und Systemaudioaufnahme** – macOS behandelt das Aufnehmen von Systemton wie eine Bildschirmaufnahme. Erlaube Tapedeck unter **Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme** und starte Tapedeck neu. Tapedeck nimmt nur Ton auf, nie den Bildschirm.

## Schneiden

![Das Schnittfenster: die Aufnahme als Tonband, darunter die Tastenreihen und die Drehknöpfe zoom und höhe](schnitt.png)

- Die Timeline ist ein Tonband: oben das Zeitlineal, darunter die Clips als Bandstücke mit Wellenform.
- **Klick** aufs Band setzt die rote Positionslinie. Zum Durchhören ziehst du im Streifen mit dem Zeitlineal.
- **in** und **out** setzen Anfang und Ende eines Bereichs. **schnitt** schneidet ihn heraus und schließt die Lücke. Die Schnittstelle zeigt ein schräger Klebestreifen. Ohne in schneidet Tapedeck vom Anfang an, ohne out bis zum Ende.
- **zurück** (⌘Z) macht jeden Schritt rückgängig.

## Abspielen

- **◂◂ rückw.**, **stop** und **vorw. ▸▸** spielen rückwärts, halten an und spielen vorwärts. Nochmal drücken macht schneller: 2×, dann 4×.
- Auf der Tastatur: **J**, **K** und **L** – wie in Schnittprogrammen. **K** gedrückt halten und **J** oder **L** tippen geht ein Bild zurück oder vor.
- **←** und **→** gehen ein Bild (1/25 Sekunde) zurück oder vor, mit Ton.
- Die **Leertaste** spielt ab und hält an.

## Dateien anfügen und Clips verschieben

- **anfügen** hängt eine oder mehrere Audiodateien (WAV, AIFF, MP3, M4A …) ans Ende. Tapedeck wandelt sie ins Format der Aufnahme um; deine Originaldateien bleiben unverändert.
- Jedes Stück der Timeline ist ein Clip: die Aufnahme, jede angefügte Datei und jedes Teil nach einem Schnitt.
- **Zieh einen Clip** mit der Maus an eine andere Stelle. Er hebt sich beim Ziehen ab, die anderen Clips machen Platz.

## Drehknöpfe

- Zum Drehen den Knopf anklicken und nach oben oder unten ziehen.
- **zoom** geht von der ganzen Aufnahme bis zur nächsten Ansicht. Auf der Tastatur: ⌘+, ⌘− und ⌘0 für die ganze Aufnahme.
- **höhe** macht die Wellenform höher – gut für leise Aufnahmen.

## Sichern oder verwerfen

- **sichern** (↩) fragt nach Ort und Namen und schreibt die geschnittene Aufnahme als WAV, 48 kHz und 24 bit.
- **verwerfen** löscht die Aufnahme nach einer Rückfrage.
- Schließt du das Schnittfenster oder beendest Tapedeck, fragt Tapedeck, ob die Aufnahme gesichert werden soll. Läuft gerade eine Aufnahme, fragt es auch.
- Stürzt Tapedeck ab, während der Schnitt offen ist, öffnet macOS ihn beim nächsten Start wieder – mit der Aufnahme.

## Tasten im Überblick

- **Leertaste** – aufnehmen / stoppen im Aufnahmefenster, abspielen / anhalten im Schnitt
- **J K L** – rückwärts / stop / vorwärts, nochmal = schneller
- **← →** oder **K + J / K + L** – ein Bild zurück / vor
- **I / O** – in / out setzen
- **X** – von in bis out herausschneiden
- **⌘Z** – rückgängig
- **⌘+ ⌘− ⌘0** – zoomen, ganze Aufnahme
- **↩** – sichern

## Updates

- Gibt es eine neue Version auf GitHub, erscheint ein kleines Fenster. **installieren** lädt sie, prüft sie, ersetzt Tapedeck und startet es neu. **später** fragt beim nächsten Mal wieder, **überspringen** meldet sich erst bei der nächsten Version.
- Von Hand: Menü **Tapedeck → Nach Updates suchen …**.
- Während einer Aufnahme oder mit ungesichertem Schnitt wartet das Update, bis du fertig bist.

## Probleme melden

Fragen und Fehler bitte unter **github.com/moritz-poth/Tapedeck/issues** melden.
