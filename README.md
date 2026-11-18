# ShortMaker

Native Mac-App, die aus langen 16:9-Videos kurze 9:16-Shorts macht – in vier Schritten:

1. **Auswahl** – Video laden und bildgenau die Stellen markieren, die ins Short sollen (In/Out, bildweises Fahren, Feinrad). Beim Übernehmen teilt ShortMaker den Bereich auf Wunsch automatisch an jedem Bildschnitt, sodass jede Einstellung ein eigener Clip wird.
2. **Format** – die Clips stehen als 9:16-Zeitleiste hintereinander. Clips lassen sich am Abspielkopf teilen (Taste **B**) und wieder verbinden, Bildschnitte auch nachträglich in allen Clips erkennen. Je Clip: Ausschnitt von Hand setzen, die Hauptperson verfolgen lassen (Apple Vision) oder das ganze Bild mit unscharfem Hintergrund zeigen. Der Ausschnitt wird auf 1080 × 1920 hochskaliert.
3. **Text** – Untertitel automatisch mit Whisper erzeugen (lokal, mit Wort-Hervorhebung) und eigene Titel im Social-Media-Stil setzen.

4. **Vorschaubild** – aus demselben Material und im selben Stil ein Titelbild erstellen, als 9:16 für das Short oder 16:9 für das lange Video. Die App schlägt Bilder mit gut sichtbarem Gesicht vor; Wörter zwischen `*Sternchen*` erscheinen in der Akzentfarbe. Sichern als JPEG oder PNG.

Export als MP4 – oder **Übergabe an YT Producer**: ShortMaker legt dort ein Projekt an, wie YT Producer es selbst für ein Short ohne Vor- und Abspann anlegt (`ON Downloads/<Sendung>/<Titel>` mit `Segmente/`, `Vorschaubilder/01.jpg`, `Transkripte/` und `project.json`). In YT Producer geht es unter „02 Projekte“ weiter.

Danach Export als MP4 (H.264 oder HEVC), wahlweise mit KI-Hochskalierung (Real-ESRGAN).

Seite: https://fmatsch.github.io/shortmaker/

## Bedienung

| Taste | Wirkung |
| --- | --- |
| Leertaste | Wiedergabe / Pause |
| ← / → | ein Bild zurück / vor (mit ⇧: zehn Bilder) |
| I / O | Anfang / Ende der Stelle auf das aktuelle Bild setzen |
| ↩ | markierten Bereich als Clip übernehmen |
| B | in Schritt 2: Clip am Abspielkopf teilen |

In den Schritten 2 und 3 lässt sich das Bild bzw. der Text direkt in der Vorschau ziehen.

## Voraussetzungen

* Apple Silicon, macOS 14 oder neuer
* Untertitel: beim ersten Gebrauch lädt die App das Whisper-Modell (large-v3 turbo, ca. 630 MB) von Hugging Face nach
  `~/Library/Application Support/ShortMaker/Models`. Danach läuft alles ohne Internet. Beim allerersten Erkennen bereitet macOS das Modell
  für die Neural Engine vor – das dauert einmalig einige Minuten.

## Selbst bauen

Es genügen die Command Line Tools, Xcode ist nicht nötig.

```bash
git clone https://github.com/fmatsch/shortmaker.git
cd shortmaker
Scripts/build_app.sh
open build/ShortMaker.app
```

Bildkette ohne Oberfläche prüfen (Zeitleiste, Verfolgung, Titel, Export):

```bash
.build/release/ShortMaker --selftest video.mp4 ausgabeordner [ai] [whisper]
```

## Grenzen dieser Version

* Ein Quellvideo je Projekt; Projekte werden noch nicht gespeichert.
* Videos mit variabler Bildrate werden als konstante Bildrate behandelt.
* Die Personenverfolgung folgt der größten erkannten Person; bei verdeckten Personen kann sie danebenliegen – dann den Ausschnitt von Hand setzen.
* Die App ist nicht notarisiert: beim ersten Start Rechtsklick → „Öffnen“.

## Lizenz

MIT. Modelle: siehe [Models/NOTICE.md](Models/NOTICE.md).
