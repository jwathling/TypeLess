# Verteilung Teil 3: Sparkle-Selbst-Update + Release-Automatik — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TypeLess über GitHub installierbar und per Sparkle selbst-aktualisierbar machen — auf den eigenen Macs des Anwenders, ohne dass Berechtigungen bei Updates neu erteilt werden müssen.

**Architecture:** Sparkle wird als Swift-Package-Abhängigkeit nur ins `TypeLess`-Executable eingebunden (`TypeLessCore` bleibt UI-/framework-frei). Das reine `swift build`-Bundle bettet `Sparkle.framework` selbst ein und signiert es von innen nach außen. Ein `release.sh` baut/signiert/packt die App zu einem ~44-MB-Zip, signiert es mit EdDSA, ergänzt eine `appcast.xml` und lädt beides als GitHub-Release hoch. Die Version stammt aus einer einzigen `VERSION`-Datei.

**Tech Stack:** Swift 6 / SwiftPM (macOS 14+), Sparkle 2.x (SwiftPM binaryTarget), Bash, Python 3.11 (nur stdlib, für den testbaren Appcast-Helfer), `gh` CLI, `codesign`, `ditto`.

## Global Constraints

- **Signatur-Identität stabil:** Code-Signatur immer mit `TypeLess Dev`, Bundle-ID immer `de.typeless.TypeLess` — über **alle** Versionen unverändert (sonst gehen die macOS-Rechte verloren).
- **Update-Modus:** automatisch prüfen, aber **vor** Download/Installation fragen. `SUEnableAutomaticChecks = true`, `SUScheduledCheckInterval = 86400`, **kein** automatisches Herunterladen/Installieren.
- **Update-Paket:** `.zip` der `.app` (~44 MB). **Kein** Delta-/Patch-Update.
- **Version aus EINER Quelle:** die Datei `VERSION` im Repo-Root. App-`Info.plist`, Zip-Name, Git-Tag und Appcast-Eintrag stammen alle daraus.
- **`TypeLessCore` bleibt frei von Sparkle** und jeglichem UI-Framework (weiter ohne Fenster unit-testbar). Sparkle lebt ausschließlich in `Sources/TypeLess/`.
- **EdDSA-Schlüssel:** privater Teil bleibt gesichert (Schlüsselbund/Backup), öffentlicher Teil steht als `SUPublicEDKey` in der `Info.plist`. Feed-URL zeigt auf die Roh-URL der `appcast.xml` bei GitHub.
- **Geheime Schlüssel kommen NIE ins (öffentliche) Repo.**
- **Deutsch** für alle Kommentare/Docs. Python: `from __future__ import annotations`, Typannotationen, Zeilenlänge 100.
- **Jeder Schritt hält die App lauffähig.** Commit/Push nur wie in den Tasks angegeben.

---

### Task 1: Version aus einer einzigen Quelle (`VERSION`-Datei)

Heute steht `0.3.0` hartcodiert im `Info.plist`-Heredoc von `scripts/build-app.sh` (Zeile 38). Das wird durch eine `VERSION`-Datei ersetzt, aus der `build-app.sh` (und später `release.sh`) liest. Ohne diesen Schritt können App-Version, Zip-Name und Appcast auseinanderlaufen.

**Files:**
- Create: `VERSION` (Repo-Root)
- Modify: `scripts/build-app.sh` (Version einlesen statt Literal; `CFBundleVersion` ergänzen)

**Interfaces:**
- Produces: `VERSION`-Datei mit **nur** der Versionsnummer (z. B. `0.4.0`, ohne `v`, ohne Zeilenkommentar). `build-app.sh` erzeugt eine `Info.plist`, deren `CFBundleShortVersionString` **und** `CFBundleVersion` diesen Wert tragen. `release.sh` (Task 5) liest dieselbe Datei.

- [ ] **Step 1: `VERSION`-Datei anlegen**

Inhalt der Datei `VERSION` (genau eine Zeile, kein `v`-Präfix):

```
0.4.0
```

(0.3.0 war der bisherige hartcodierte Stand; die erste über Sparkle ausgelieferte Version wird 0.4.0.)

- [ ] **Step 2: `build-app.sh` die Version einlesen lassen**

In `scripts/build-app.sh` **nach** Zeile 18 (`BUNDLE_ID="de.typeless.TypeLess"`) einfügen:

```bash
# Version aus EINER Quelle (Repo-Root/VERSION) — App-Info.plist, Zip-Name (release.sh) und
# Appcast dürfen nie auseinanderlaufen. Das Anheben der Version ist ein bewusster Edit von VERSION.
VERSION="$(tr -d ' \t\n\r' < "$SCRIPT_DIR/../VERSION")"
[ -n "$VERSION" ] || { echo "FEHLER: VERSION-Datei leer oder fehlt ($SCRIPT_DIR/../VERSION)" >&2; exit 1; }
echo "== Version aus VERSION-Datei: $VERSION =="
```

- [ ] **Step 3: Die `Info.plist`-Zeile auf die Variable umstellen**

In `scripts/build-app.sh` die Zeile (aktuell Zeile 38):

```
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
```

ersetzen durch (beide Schlüssel, damit Sparkle eine eindeutige Build-Version hat):

```
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
```

(Das Heredoc `<<PLIST` ist nicht quotiert, daher wird `$VERSION` expandiert — bestehendes Verhalten für `$BUNDLE_ID` bestätigt das.)

- [ ] **Step 4: Bauen und die Version in der erzeugten Plist prüfen**

Run:
```bash
bash scripts/build-app.sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' apps/macos/TypeLess.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' apps/macos/TypeLess.app/Contents/Info.plist
```
Expected: beide Kommandos geben `0.4.0` aus; das Skript endet mit `Fertig: apps/macos/TypeLess.app`.

- [ ] **Step 5: Commit**

```bash
git add VERSION scripts/build-app.sh
git commit -m "M8-Verteilung Teil3: Version aus einer Quelle (VERSION-Datei)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Testbarer Appcast-Helfer (`scripts/release_appcast.py`)

Die einzige rein logische, ohne Bauen/Netz testbare Einheit von Teil 3: „gegebenes Appcast-XML + neuer Release-Eintrag → aktualisiertes XML" — idempotent (dieselbe Version zweimal erzeugt keinen doppelten Eintrag). `release.sh` (Task 5) ruft dieses Skript auf.

**Files:**
- Create: `scripts/release_appcast.py`
- Test: `scripts/test_release_appcast.py`

**Interfaces:**
- Produces: Funktion `upsert_item(appcast_xml: str, *, version: str, url: str, length: int, ed_signature: str, pub_date: str) -> str`. Nimmt bestehendes Appcast-XML (leerer String → frisches Gerüst), fügt einen `<item>` für `version` **vorn** in den Channel ein; ist `version` bereits vorhanden, wird das XML **unverändert** zurückgegeben. Rückgabe ist wohlgeformtes RSS-XML mit dem Sparkle-Namespace.
- Produces: CLI `python3 scripts/release_appcast.py <appcast-datei> --version V --url U --length N --ed-signature S --pub-date D [--stdout]`. Ohne `--stdout` wird die Datei in-place aktualisiert (fehlt sie, wird das Gerüst erzeugt); mit `--stdout` wird das Ergebnis nur ausgegeben (für `release.sh --dry-run`).

- [ ] **Step 1: Die fehlschlagenden Tests schreiben**

Datei `scripts/test_release_appcast.py`:

```python
"""Tests für den Appcast-Helfer — reine Logik, kein Bauen, kein Netz."""
from __future__ import annotations

import xml.etree.ElementTree as ET

import release_appcast

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def _items(xml: str) -> list[ET.Element]:
    root = ET.fromstring(xml)
    return root.findall("./channel/item")


def test_leeres_appcast_erzeugt_geruest_mit_einem_item() -> None:
    xml = release_appcast.upsert_item(
        "", version="0.4.0", url="https://example/TypeLess-0.4.0.zip",
        length=44_000_000, ed_signature="SIG_A", pub_date="Wed, 23 Jul 2026 10:00:00 +0000")
    items = _items(xml)
    assert len(items) == 1
    assert items[0].find(f"{{{SPARKLE}}}version").text == "0.4.0"
    enclosure = items[0].find("enclosure")
    assert enclosure.get("url") == "https://example/TypeLess-0.4.0.zip"
    assert enclosure.get("length") == "44000000"
    assert enclosure.get(f"{{{SPARKLE}}}edSignature") == "SIG_A"


def test_zweite_version_wird_vorn_eingefuegt() -> None:
    erst = release_appcast.upsert_item(
        "", version="0.4.0", url="https://example/TypeLess-0.4.0.zip",
        length=1, ed_signature="SIG_A", pub_date="Wed, 23 Jul 2026 10:00:00 +0000")
    zweit = release_appcast.upsert_item(
        erst, version="0.5.0", url="https://example/TypeLess-0.5.0.zip",
        length=2, ed_signature="SIG_B", pub_date="Thu, 24 Jul 2026 10:00:00 +0000")
    versionen = [i.find(f"{{{SPARKLE}}}version").text for i in _items(zweit)]
    assert versionen == ["0.5.0", "0.4.0"]  # neueste zuerst


def test_dieselbe_version_ist_idempotent() -> None:
    erst = release_appcast.upsert_item(
        "", version="0.4.0", url="https://example/TypeLess-0.4.0.zip",
        length=1, ed_signature="SIG_A", pub_date="Wed, 23 Jul 2026 10:00:00 +0000")
    nochmal = release_appcast.upsert_item(
        erst, version="0.4.0", url="https://example/TypeLess-0.4.0-neu.zip",
        length=999, ed_signature="SIG_NEU", pub_date="Fri, 25 Jul 2026 10:00:00 +0000")
    assert nochmal == erst  # kein zweiter Eintrag, nichts überschrieben
    assert len(_items(nochmal)) == 1
```

- [ ] **Step 2: Tests ausführen und Fehlschlag bestätigen**

Run (vom Repo-Root; nutzt die vorhandene Engine-Dev-Umgebung, in der pytest liegt):
```bash
uv run --project engine pytest scripts/test_release_appcast.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'release_appcast'`.

- [ ] **Step 3: Den Helfer implementieren**

Datei `scripts/release_appcast.py`:

```python
"""Fügt einen Release-Eintrag in eine Sparkle-`appcast.xml` ein (idempotent).

Reine stdlib — von `scripts/release.sh` aufgerufen, für sich testbar (kein Bauen, kein Netz).
"""
from __future__ import annotations

import argparse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

_GERUEST = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    f'<rss version="2.0" xmlns:sparkle="{SPARKLE}">\n'
    "  <channel>\n"
    "    <title>TypeLess</title>\n"
    "  </channel>\n"
    "</rss>\n"
)


def upsert_item(
    appcast_xml: str,
    *,
    version: str,
    url: str,
    length: int,
    ed_signature: str,
    pub_date: str,
) -> str:
    """Fügt vorn einen `<item>` für `version` ein; ist die Version schon da, unverändert zurück."""
    ET.register_namespace("sparkle", SPARKLE)
    root = ET.fromstring(appcast_xml if appcast_xml.strip() else _GERUEST)
    channel = root.find("./channel")
    if channel is None:  # pragma: no cover — nur bei kaputtem Eingabe-XML
        raise ValueError("appcast.xml ohne <channel>")

    for item in channel.findall("item"):
        vorhandene = item.find(f"{{{SPARKLE}}}version")
        if vorhandene is not None and vorhandene.text == version:
            return appcast_xml  # idempotent: bereits veröffentlicht

    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, "pubDate").text = pub_date
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", url)
    enclosure.set("type", "application/octet-stream")
    enclosure.set("length", str(length))
    enclosure.set(f"{{{SPARKLE}}}edSignature", ed_signature)

    # Neueste Version zuerst: direkt hinter <title> (dem ersten Kind des Channels) einsetzen.
    channel.insert(1, item)
    ET.indent(root, space="  ")
    return ET.tostring(root, encoding="unicode", xml_declaration=True) + "\n"


def main() -> None:
    p = argparse.ArgumentParser(description="Appcast-Eintrag einfügen (idempotent).")
    p.add_argument("appcast")
    p.add_argument("--version", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--length", type=int, required=True)
    p.add_argument("--ed-signature", required=True)
    p.add_argument("--pub-date", required=True)
    p.add_argument("--stdout", action="store_true", help="nur ausgeben, Datei nicht schreiben")
    args = p.parse_args()

    try:
        with open(args.appcast, encoding="utf-8") as f:
            bestehend = f.read()
    except FileNotFoundError:
        bestehend = ""

    ergebnis = upsert_item(
        bestehend, version=args.version, url=args.url, length=args.length,
        ed_signature=args.ed_signature, pub_date=args.pub_date)

    if args.stdout:
        print(ergebnis, end="")
    else:
        with open(args.appcast, "w", encoding="utf-8") as f:
            f.write(ergebnis)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Tests ausführen und Erfolg bestätigen**

Run:
```bash
uv run --project engine pytest scripts/test_release_appcast.py -v
```
Expected: PASS — 3 passed.

- [ ] **Step 5: Commit**

```bash
git add scripts/release_appcast.py scripts/test_release_appcast.py
git commit -m "M8-Verteilung Teil3: testbarer Appcast-Helfer (idempotenter Eintrag)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Sparkle einbinden, instanziieren und ins Bundle einbetten (RISIKO-SPIKE)

**Das ist der eine Teil, der scheitern kann** — analog zur Python-Bündelung in Teil 1. Sparkle über reines `swift build` (ohne Xcode-Copy-Phasen) einzubetten heißt: `Sparkle.framework` selbst nach `Contents/Frameworks/` kopieren, den rpath setzen und die verschachtelten Sparkle-Helfer (XPCServices, Autoupdate, Updater.app) **von innen nach außen** signieren. Go/No-Go: Die gebaute App startet mit **geladenem** Sparkle-Framework ohne dyld-Absturz, und `codesign --verify --deep --strict` ist grün.

Sparkle-Referenz zur Einbettung ohne Xcode: <https://sparkle-project.org/documentation/> (Abschnitt „Sparkle via Swift Package Manager"). Die exakten Pfade des Frameworks im Build-Output beim Ausführen mit `find` verifizieren.

**Files:**
- Modify: `apps/macos/Package.swift` (Sparkle-Dependency + rpath-Linkerflag)
- Create: `apps/macos/Sources/TypeLess/UpdaterController.swift` (Grundgerüst, instanziiert Sparkle)
- Modify: `apps/macos/Sources/TypeLess/TypeLessApp.swift` (Controller halten, damit Sparkle beim Start wirklich lädt)
- Modify: `scripts/build-app.sh` (Framework einbetten + signieren)

**Interfaces:**
- Produces: `UpdaterController` (`@MainActor final class`), Initializer `init()`, hält eine `SPUStandardUpdaterController`-Instanz. In Task 4 kommt `checkForUpdates()` und die Aktivierungslogik dazu.
- Produces: gebautes `TypeLess.app` mit `Contents/Frameworks/Sparkle.framework` und korrekt gesetztem rpath.

- [ ] **Step 1: Sparkle als Dependency + rpath in `Package.swift`**

`apps/macos/Package.swift` komplett ersetzen durch:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeLess",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Selbst-Update außerhalb des App Store. Nur an das App-Target gebunden — TypeLessCore
        // bleibt framework-frei und ohne Fenster testbar.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Bibliothek ohne jede UI — deshalb vollständig testbar, ohne ein Fenster zu öffnen.
        .target(name: "TypeLessCore"),
        // Die SwiftUI-Hülle. Bewusst dünn: zeigt nur an, was AppState sagt.
        .executableTarget(
            name: "TypeLess",
            dependencies: ["TypeLessCore", .product(name: "Sparkle", package: "Sparkle")],
            // Das eingebettete Framework liegt im .app unter Contents/Frameworks; der Loader muss
            // es relativ zum Executable finden (build-app.sh kopiert es dorthin).
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]),
        .testTarget(name: "TypeLessCoreTests", dependencies: ["TypeLessCore"]),
    ]
)
```

- [ ] **Step 2: `swift build` prüft die Dependency-Auflösung**

Run:
```bash
cd apps/macos && swift build 2>&1 | tail -5
```
Expected: Sparkle wird aufgelöst und geladen (`Build complete!`). Falls der Build wegen des rpath-Flags oder der Sparkle-Version scheitert, ist das hier — vor jeder weiteren Arbeit — zu klären.

- [ ] **Step 3: `UpdaterController`-Grundgerüst**

Datei `apps/macos/Sources/TypeLess/UpdaterController.swift`:

```swift
import Sparkle

/// Kapselt Sparkles Updater. Bewusst in der App-Schicht (nicht in TypeLessCore) — Sparkle ist ein
/// UI-Framework. In diesem Task nur instanziiert, damit das eingebettete Framework beim Start
/// tatsächlich geladen wird (Einbettungs-Beweis); die Betriebsart (automatisch prüfen, vorher
/// fragen) und der Menü-Auslöser kommen in Task 4.
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true → der Updater startet mit; ohne Feed-URL/Key (Task 4) prüft er
        // nichts, stürzt aber auch nicht ab. Kein Delegate nötig für die reine Instanziierung.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
}
```

- [ ] **Step 4: Controller in `TypeLessApp` halten (Sparkle beim Start laden)**

In `apps/macos/Sources/TypeLess/TypeLessApp.swift` in `struct TypeLessApp` nach der Zeile `@State private var dictation: DictationCoordinator` (Zeile 12) einfügen:

```swift
    // Hält Sparkle am Leben. Instanziierung hier lädt das eingebettete Framework beim Start —
    // der eigentliche Einbettungs-Beweis dieses Tasks.
    @State private var updater = UpdaterController()
```

(Der `@State`-Default-Initializer `UpdaterController()` läuft beim App-Aufbau — kein weiterer Verdrahtungscode nötig, um Sparkle zu laden.)

- [ ] **Step 5: Bestehende Swift-Tests laufen weiter**

Run:
```bash
cd apps/macos && swift test 2>&1 | tail -5
```
Expected: unverändert grün (TypeLessCore ist von Sparkle unberührt; das eine Mikrofon-Hardware-Test-Ergebnis hängt von der Umgebung ab und ist nicht Teil dieser Änderung).

- [ ] **Step 6: `Sparkle.framework` ins Bundle einbetten + von innen nach außen signieren**

In `scripts/build-app.sh` **vor** dem Signatur-Block (aktuell ab Zeile 71 `# macOS bindet …`) diesen Abschnitt einfügen:

```bash
# --- Sparkle.framework einbetten (Selbst-Update) ---
# Reines `swift build` hat keine Xcode-Copy-Phase; das Framework wird von Hand ins Bundle gelegt.
# Sparkle bringt verschachtelte Helfer mit (XPCServices, Autoupdate, Updater.app), die einzeln und
# VON INNEN NACH AUSSEN signiert werden müssen — `--deep` allein signiert sie nicht zuverlässig.
SPARKLE_FW="$(find "$(swift build -c "$CONFIG" --show-bin-path)" -maxdepth 1 -name 'Sparkle.framework' -type d | head -1)"
[ -n "$SPARKLE_FW" ] || { echo "FEHLER: Sparkle.framework im Build-Output nicht gefunden" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
echo "== Sparkle.framework eingebettet aus $SPARKLE_FW =="
```

- [ ] **Step 7: Die verschachtelten Sparkle-Teile in den Signatur-Block aufnehmen**

Der bestehende Signatur-Block (`codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"` bzw. der Ad-hoc-Zweig) signiert die App als Ganzes. Sparkle braucht die verschachtelten Helfer **zuerst**, einzeln. Den `if …; then … else … fi`-Block ab Zeile 81 ersetzen durch:

```bash
SIGN_IDENTITY="${TYPELESS_SIGN_IDENTITY:-TypeLess Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  echo "== signieren mit stabiler Identität: $SIGN_IDENTITY =="
else
  SIGN_ARGS=(--force --sign -)
  echo "== stabile Identität '$SIGN_IDENTITY' nicht gefunden — ad-hoc (Rechte gehen bei jedem Neubau verloren) =="
  echo "   Einmalig einrichten: bash scripts/setup-signing-identity.sh"
fi

# Von innen nach außen: erst die verschachtelten Sparkle-Helfer, dann das Framework, zuletzt die App.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  while IFS= read -r -d '' nested; do
    codesign "${SIGN_ARGS[@]}" "$nested"
  done < <(find "$FW/Versions/Current" \( -name '*.xpc' -o -name '*.app' -o -name 'Autoupdate' \) -print0)
  codesign "${SIGN_ARGS[@]}" "$FW"
fi
codesign "${SIGN_ARGS[@]}" "$APP"
```

(Der alte `--deep` entfällt: die verschachtelten Teile werden jetzt explizit signiert, das ist robuster und nicht deprecated.)

- [ ] **Step 8: Bauen, Signatur verifizieren, Start prüfen (Go/No-Go)**

Run:
```bash
bash scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 apps/macos/TypeLess.app && echo "SIGNATUR_OK"
test -d apps/macos/TypeLess.app/Contents/Frameworks/Sparkle.framework && echo "FRAMEWORK_DA"
# Startet die App mit geladenem Sparkle ohne dyld-Absturz? (LSUIElement — kein Fenster; nach ~3 s beenden.)
open apps/macos/TypeLess.app && sleep 3 && osascript -e 'tell application "TypeLess" to quit' 2>/dev/null; \
  pgrep -x TypeLess >/dev/null && { echo "LAEUFT_NOCH — manuell beenden"; osascript -e 'quit app "TypeLess"' 2>/dev/null; } ; echo "START_OK"
```
Expected: `SIGNATUR_OK`, `FRAMEWORK_DA`, `START_OK` — die App startet ohne Absturz (kein „dyld: Library not loaded: @rpath/Sparkle.framework"). Erscheint ein dyld-Fehler, ist der rpath (Step 1) oder der Framework-Pfad (Step 6) falsch — hier klären, bevor es weitergeht.

- [ ] **Step 9: Commit**

```bash
git add apps/macos/Package.swift apps/macos/Package.resolved apps/macos/Sources/TypeLess/UpdaterController.swift apps/macos/Sources/TypeLess/TypeLessApp.swift scripts/build-app.sh
git commit -m "M8-Verteilung Teil3: Sparkle einbinden + Framework ins Bundle einbetten und signieren

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: EdDSA-Schlüssel, Info.plist-Sparkle-Schlüssel und Menüpunkt „Nach Updates suchen…"

Jetzt bekommt Sparkle seine Betriebsart (automatisch prüfen, vorher fragen), die Feed-URL (mit Platzhalter-Benutzername bis Task 6), den öffentlichen EdDSA-Schlüssel und einen manuellen Auslöser im Menü. Weil TypeLess `LSUIElement` ist, muss der Update-Dialog nach vorn geholt werden (wie das Einrichtungs-Fenster in Teil 2b).

**Files:**
- Create: `apps/macos/sparkle_public_key.txt` (öffentlicher EdDSA-Schlüssel, **nicht** geheim)
- Modify: `scripts/build-app.sh` (Sparkle-Schlüssel in die `Info.plist`)
- Modify: `apps/macos/Sources/TypeLess/UpdaterController.swift` (`checkForUpdates()` + Aktivierung)
- Modify: `apps/macos/Sources/TypeLess/MenuContent.swift` (Menüpunkt)
- Modify: `apps/macos/Sources/TypeLess/TypeLessApp.swift` (Menüpunkt-Aktion verdrahten)

**Interfaces:**
- Consumes: `UpdaterController` aus Task 3.
- Produces: `UpdaterController.checkForUpdates()` (`@MainActor`), das den Update-Check auslöst und die App vorher per `NSApp.activate(ignoringOtherApps:)` in den Vordergrund holt.
- Produces: `MenuContent` erhält eine neue Eigenschaft `let checkForUpdates: () -> Void` und einen Button „Nach Updates suchen…".

- [ ] **Step 1: EdDSA-Schlüsselpaar erzeugen (einmaliger Handschritt)**

Sparkles `generate_keys` liegt nach Task 3 im aufgelösten Sparkle-Artefakt. Erzeugen und den **öffentlichen** Schlüssel ablegen:

```bash
GEN="$(find apps/macos/.build -name generate_keys -type f -perm -u+x | head -1)"
[ -n "$GEN" ] || { echo "generate_keys nicht gefunden — swift build in apps/macos ausführen"; }
# Legt den PRIVATEN Schlüssel im Schlüsselbund ab (bleibt dort, kommt NIE ins Repo) und gibt den
# öffentlichen aus. Läuft nur beim allerersten Mal; existiert der Schlüssel schon, meldet es das.
"$GEN"
# Den ausgegebenen öffentlichen Schlüssel (Base64, Feld "SUPublicEDKey") in die Datei schreiben:
"$GEN" -p > apps/macos/sparkle_public_key.txt
cat apps/macos/sparkle_public_key.txt
```
Expected: `apps/macos/sparkle_public_key.txt` enthält eine Base64-Zeile (der öffentliche Schlüssel). Der private Schlüssel liegt im Schlüsselbund. **Sicherung des privaten Schlüssels erfolgt in Task 6.**

> Umsetzer-Hinweis: `generate_keys -p` gibt nur den öffentlichen Schlüssel aus (idempotent, erzeugt keinen neuen). Falls diese Umgebung keinen Schlüsselbund-Zugriff hat (Subagent), lege stattdessen einen klar erkennbaren Platzhalter `PLACEHOLDER_ED_PUBLIC_KEY` in die Datei und vermerke das im Report — der echte Schlüssel wird dann in Task 6 vom Menschen erzeugt und eingesetzt. Der Code/das Skript muss mit beidem gleich funktionieren.

- [ ] **Step 2: Sparkle-Schlüssel in die `Info.plist` schreiben (`build-app.sh`)**

In `scripts/build-app.sh` **vor** dem Heredoc `cat > "$APP/Contents/Info.plist"` (aktuell Zeile 29) einlesen:

```bash
# Öffentlicher EdDSA-Schlüssel (nicht geheim) für Sparkles Update-Verifikation.
ED_PUBLIC_KEY="$(tr -d ' \t\n\r' < "$SCRIPT_DIR/../apps/macos/sparkle_public_key.txt" 2>/dev/null || true)"
[ -n "$ED_PUBLIC_KEY" ] || echo "WARNUNG: kein Sparkle-Public-Key (sparkle_public_key.txt) — Updates nicht verifizierbar" >&2
# Feed-URL: Roh-URL der appcast.xml im GitHub-Repo. Der Benutzername wird in Task 6 gesetzt.
SU_FEED_URL="${TYPELESS_FEED_URL:-https://raw.githubusercontent.com/PLACEHOLDER_GH_USER/TypeLess/main/appcast.xml}"
```

Im Heredoc **vor** der abschließenden `</dict>`-Zeile (nach dem `NSMicrophoneUsageDescription`-Block) einfügen:

```
    <!-- Selbst-Update (M8-Verteilung Teil 3): automatisch prüfen, aber VOR Download/Installation
         fragen. Kein automatisches Herunterladen/Installieren. -->
    <key>SUFeedURL</key><string>$SU_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$ED_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
```

- [ ] **Step 3: `UpdaterController` um `checkForUpdates()` + Aktivierung erweitern**

`apps/macos/Sources/TypeLess/UpdaterController.swift` ersetzen durch:

```swift
import AppKit
import Sparkle

/// Kapselt Sparkles Updater. Bewusst in der App-Schicht (nicht in TypeLessCore) — Sparkle ist ein
/// UI-Framework. Betriebsart „automatisch prüfen, aber vor Download/Installation fragen" steckt in
/// der Info.plist (SUEnableAutomaticChecks / SUScheduledCheckInterval, kein Auto-Download).
@MainActor
final class UpdaterController: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // userDriverDelegate: self → wir werden vor dem Anzeigen eines Update-Dialogs gefragt und
        // holen die (dock-lose LSUIElement-)App dann in den Vordergrund.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Manueller Auslöser aus dem Menü. `NSApp.activate` bringt den Dialog vor — ohne das bliebe er
    /// bei einer Hintergrund-App (LSUIElement) unsichtbar hinter anderen Fenstern.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // SPUStandardUserDriverDelegate: auch der automatische Fund soll sichtbar nach vorn kommen.
    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
```

- [ ] **Step 4: Menüpunkt in `MenuContent`**

In `apps/macos/Sources/TypeLess/MenuContent.swift`:

Nach `let dictation: DictationCoordinator` (Zeile 10) einfügen:
```swift
    /// Löst den Sparkle-Update-Check aus (Verdrahtung in TypeLessApp; hier nur ein Auslöser, keine
    /// Logik — MenuContent bleibt anzeigend).
    let checkForUpdates: () -> Void
```

Im `body` **vor** der Zeile `Button("Engine neu starten")` (Zeile 60) einfügen:
```swift
        Button("Nach Updates suchen …") {
            checkForUpdates()
        }
```

- [ ] **Step 5: Menüpunkt in `TypeLessApp` verdrahten**

In `apps/macos/Sources/TypeLess/TypeLessApp.swift` im `body` den `MenuContent`-Aufruf (Zeile 72) ersetzen:

```swift
            MenuContent(state: state, dictation: dictation, checkForUpdates: updater.checkForUpdates)
```

- [ ] **Step 6: Bauen + bestehende Tests grün**

Run:
```bash
cd apps/macos && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3
```
Expected: `Build complete!`; bestehende Tests unverändert grün.

- [ ] **Step 7: Info.plist-Schlüssel im gebauten Bundle prüfen**

Run:
```bash
bash scripts/build-app.sh >/dev/null
for k in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUScheduledCheckInterval; do
  printf '%s = ' "$k"; /usr/libexec/PlistBuddy -c "Print :$k" apps/macos/TypeLess.app/Contents/Info.plist
done
```
Expected: `SUFeedURL` = eine `raw.githubusercontent.com/.../appcast.xml`-URL, `SUPublicEDKey` = der Base64-Schlüssel (oder Platzhalter, s. Step 1), `SUEnableAutomaticChecks` = `true`, `SUScheduledCheckInterval` = `86400`.

- [ ] **Step 8: Handprobe-Notiz + Commit**

Handprobe (nur wenn der echte EdDSA-Schlüssel vorliegt): App starten → Menü öffnen → „Nach Updates suchen …" zeigt einen Sparkle-Dialog im Vordergrund (mangels erreichbarem Appcast „kann nicht nach Updates suchen" — das beweist Sichtbarkeit + Aktivierung). In den Report schreiben, ob ausgeführt oder aufgeschoben.

```bash
git add apps/macos/sparkle_public_key.txt scripts/build-app.sh apps/macos/Sources/TypeLess/UpdaterController.swift apps/macos/Sources/TypeLess/MenuContent.swift apps/macos/Sources/TypeLess/TypeLessApp.swift
git commit -m "M8-Verteilung Teil3: Sparkle-Betriebsart, Info.plist-Schluessel + Menuepunkt 'Nach Updates suchen'

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `scripts/release.sh` — bauen, packen, EdDSA-signieren, Appcast, Upload

Ein Skript, das `build-app.sh` wiederverwendet und darum die Release-Schritte legt. Mit `--dry-run` läuft alles außer Upload/Push — so ist der kritische Teil (korrekter Appcast-Eintrag, Version aus einer Quelle) prüfbar, ohne ein echtes Release zu erzeugen.

**Files:**
- Create: `scripts/release.sh`
- Create/Modify: `appcast.xml` (Repo-Root — wird beim ersten echten Release erzeugt; im Dry-Run nur nach stdout)

**Interfaces:**
- Consumes: `VERSION` (Task 1), `scripts/build-app.sh` (Task 1/3/4), `scripts/release_appcast.py` (Task 2), Sparkles `sign_update` (aus dem Sparkle-Artefakt, Task 3).
- Produces: `scripts/release.sh [--dry-run]`. Ohne Flag: baut, packt `TypeLess-<version>.zip`, signiert per EdDSA, ergänzt `appcast.xml`, lädt per `gh release create <version>` hoch und pusht `appcast.xml`. Mit `--dry-run`: alles bis auf `gh release create`/Push; zeigt den neuen Appcast-Eintrag auf stdout.

- [ ] **Step 1: `release.sh` schreiben**

Datei `scripts/release.sh`:

```bash
#!/usr/bin/env bash
# Baut, signiert, packt und veröffentlicht eine TypeLess-Version als GitHub-Release + Appcast.
#
# Version kommt aus EINER Quelle (VERSION). --dry-run läuft ohne Upload/Push (baut, packt,
# EdDSA-signiert, zeigt den Appcast-Eintrag) — der testbare Kern.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

VERSION="$(tr -d ' \t\n\r' < "$REPO/VERSION")"
[ -n "$VERSION" ] || { echo "FEHLER: VERSION leer" >&2; exit 1; }
APP="$REPO/apps/macos/TypeLess.app"
ZIP="$REPO/TypeLess-$VERSION.zip"
APPCAST="$REPO/appcast.xml"
GH_USER="${TYPELESS_GH_USER:-PLACEHOLDER_GH_USER}"
ASSET_URL="https://github.com/$GH_USER/TypeLess/releases/download/$VERSION/TypeLess-$VERSION.zip"

echo "== 1/6 bauen + signieren (Release) =="
bash "$SCRIPT_DIR/build-app.sh" release

echo "== 2/6 Signatur verifizieren =="
codesign --verify --deep --strict "$APP"

echo "== 3/6 packen: $ZIP =="
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"   # ditto erhält Signatur + Symlinks des Frameworks
LENGTH="$(stat -f%z "$ZIP")"

echo "== 4/6 EdDSA-Signatur des Zips =="
SIGN_UPDATE="$(find "$REPO/apps/macos/.build" -name sign_update -type f -perm -u+x | head -1)"
[ -n "$SIGN_UPDATE" ] || { echo "FEHLER: sign_update nicht gefunden (swift build in apps/macos?)" >&2; exit 1; }
# sign_update gibt eine Zeile wie: sparkle:edSignature="…" length="…"  — wir brauchen die Signatur.
SIGN_OUT="$("$SIGN_UPDATE" "$ZIP")"
ED_SIG="$(printf '%s' "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] || { echo "FEHLER: EdDSA-Signatur nicht aus sign_update-Ausgabe gelesen: $SIGN_OUT" >&2; exit 1; }
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

echo "== 5/6 Appcast-Eintrag (idempotent) =="
APPCAST_ARGS=("$APPCAST" --version "$VERSION" --url "$ASSET_URL" --length "$LENGTH"
              --ed-signature "$ED_SIG" --pub-date "$PUB_DATE")
if [ "$DRY_RUN" = "1" ]; then
  echo "-- DRY-RUN: neuer Appcast-Eintrag (nicht geschrieben, nicht veröffentlicht) --"
  uv run --project "$REPO/engine" python "$SCRIPT_DIR/release_appcast.py" "${APPCAST_ARGS[@]}" --stdout
  echo "-- DRY-RUN Ende: Zip liegt unter $ZIP ($LENGTH Bytes) --"
  exit 0
fi
uv run --project "$REPO/engine" python "$SCRIPT_DIR/release_appcast.py" "${APPCAST_ARGS[@]}"

echo "== 6/6 veröffentlichen: gh release create $VERSION =="
gh release create "$VERSION" "$ZIP" --title "TypeLess $VERSION" --notes "TypeLess $VERSION"
git add "$APPCAST"
git commit -m "Release $VERSION: appcast.xml"
git push
echo "Fertig: $VERSION veröffentlicht."
```

- [ ] **Step 2: Ausführbar machen**

Run:
```bash
chmod +x scripts/release.sh
```

- [ ] **Step 3: Dry-Run ausführen (der testbare Kern)**

Run:
```bash
bash scripts/release.sh --dry-run
```
Expected: Baut die App, packt `TypeLess-0.4.0.zip`, erzeugt eine EdDSA-Signatur und gibt einen Appcast-`<item>`-Block mit `sparkle:version` `0.4.0`, der `ASSET_URL` und `length` aus. Endet mit `DRY-RUN Ende`. Kein `gh`-Aufruf, kein Commit/Push, kein `appcast.xml` geschrieben.

> Umsetzer-Hinweis: Steht in dieser Umgebung kein EdDSA-Privatschlüssel im Schlüsselbund (s. Task 4 Step 1), schlägt Schritt 4/6 fehl. Dann den Dry-Run bis einschließlich Schritt 3/6 (Zip + Length) verifizieren, den Fehlpunkt im Report benennen und den vollständigen Dry-Run dem Menschen in Task 6/7 überlassen. Die Idempotenz des Appcast-Teils ist bereits durch Task 2 unit-belegt.

- [ ] **Step 4: Idempotenz-Kontrolle (falls Schritt 3 vollständig lief)**

Run (nur wenn der Dry-Run in Step 3 bis zum Appcast-Block durchlief — schreibt testweise eine Datei und ruft den Helfer zweimal):
```bash
python3 - <<'PY'
import subprocess, sys, pathlib
sys.path.insert(0, "scripts")
import release_appcast
a = release_appcast.upsert_item("", version="0.4.0", url="u", length=1, ed_signature="s", pub_date="d")
b = release_appcast.upsert_item(a, version="0.4.0", url="u2", length=2, ed_signature="s2", pub_date="d2")
assert a == b, "nicht idempotent!"
print("IDEMPOTENT_OK")
PY
```
Expected: `IDEMPOTENT_OK`.

- [ ] **Step 5: Commit**

```bash
git add scripts/release.sh
git commit -m "M8-Verteilung Teil3: release.sh (bauen/packen/EdDSA/appcast/--dry-run)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: GitHub-Repo, echte Feed-URL, Schlüssel-Sicherung, `docs/RELEASE.md`

Die verbleibenden **einmaligen** Einrichtungs- und Betriebsschritte. Teils Menschen-Aktionen (`gh auth`, Schlüssel-Backup an einen sicheren Ort) — im Plan klar als solche markiert.

**Files:**
- Modify: `scripts/build-app.sh` + `scripts/release.sh` (Platzhalter-Benutzername → echter, über eine Stelle)
- Create: `docs/RELEASE.md`
- Create: `.gitignore`-Einträge für die geheimen Schlüssel-Exporte

**Interfaces:**
- Consumes: alles aus Tasks 1–5.
- Produces: ein öffentliches GitHub-Repo `TypeLess` mit `origin`-Remote; `RELEASE.md` als verbindliche Betriebsanleitung.

- [ ] **Step 1: GitHub-Repo anlegen (Menschen-Schritt, falls `gh` noch nicht authentifiziert)**

```bash
gh auth status || gh auth login    # interaktiv — nur falls nötig
gh repo create TypeLess --public --source=. --remote=origin --push
git remote -v
```
Expected: `origin` zeigt auf `github.com/<user>/TypeLess`. Den tatsächlichen `<user>` notieren.

- [ ] **Step 2: Benutzername an einer Stelle setzen (Feed-URL + Asset-URL)**

Die beiden Skripte lesen den Benutzernamen aus einer Umgebungsvariable mit sinnvollem Default. Statt Platzhalter im Code den echten `<user>` als Default eintragen. In `scripts/build-app.sh` die Zeile mit `TYPELESS_FEED_URL` (Task 4) ändern, sodass der Default den echten Benutzer nennt:

```bash
SU_FEED_URL="${TYPELESS_FEED_URL:-https://raw.githubusercontent.com/<user>/TypeLess/main/appcast.xml}"
```

Und in `scripts/release.sh` die Zeile `GH_USER="${TYPELESS_GH_USER:-PLACEHOLDER_GH_USER}"`:

```bash
GH_USER="${TYPELESS_GH_USER:-<user>}"
```

(`<user>` durch den echten GitHub-Benutzernamen aus Step 1 ersetzen.)

- [ ] **Step 3: Echten EdDSA-Schlüssel erzeugen und einsetzen (falls in Task 4 aufgeschoben)**

Nur nötig, wenn `apps/macos/sparkle_public_key.txt` noch den Platzhalter enthält:

```bash
GEN="$(find apps/macos/.build -name generate_keys -type f -perm -u+x | head -1)"
"$GEN"                                  # erzeugt Privatschlüssel im Schlüsselbund (einmalig)
"$GEN" -p > apps/macos/sparkle_public_key.txt
grep -q PLACEHOLDER apps/macos/sparkle_public_key.txt && { echo "noch Platzhalter!"; exit 1; }
echo "Public-Key gesetzt."
```

- [ ] **Step 4: Schlüssel sichern (Menschen-Schritt, Definition-of-Done)**

Beide Schlüssel exportieren. **Der Ablageort des Backups ist Anwender-Entscheidung** (Passwortmanager oder verschlüsseltes externes Backup) — die Exporte kommen **nicht** ins Repo.

```bash
# 1) Code-Signing-Identität "TypeLess Dev" als passwortgeschützte .p12 (Zertifikat inkl. Privatschlüssel):
#    Schlüsselbund öffnen → "TypeLess Dev" → Rechtsklick → Exportieren → .p12, Passwort vergeben.
#    (CLI-Alternative:)
security find-certificate -c "TypeLess Dev" -a >/dev/null && echo "Identität im Schlüsselbund gefunden"
# 2) Privater Sparkle-EdDSA-Schlüssel:
GEN="$(find apps/macos/.build -name generate_keys -type f -perm -u+x | head -1)"
"$GEN" -x "$HOME/typeless-sparkle-private-key.txt"   # NICHT ins Repo; an sicheren Ort verschieben
echo "Beide Exporte an einen sicheren Ort bringen (Passwortmanager / verschlüsseltes Backup)."
```

- [ ] **Step 5: Geheimnisse aus dem Repo halten**

Falls noch keine `.gitignore` existiert, anlegen; sonst ergänzen — diese Einträge müssen enthalten sein:

```
# TypeLess-Verteilung: geheime Schlüssel-Exporte NIE einchecken
*.p12
typeless-sparkle-private-key.txt
TypeLess-*.zip
```

Prüfen, dass nichts Geheimes vorgemerkt ist:
```bash
git status --porcelain | grep -E '\.p12|sparkle-private|TypeLess-.*\.zip' && echo "STOP: Geheimnis vorgemerkt!" || echo "sauber"
```
Expected: `sauber`.

- [ ] **Step 6: `docs/RELEASE.md` schreiben**

Datei `docs/RELEASE.md`:

```markdown
# TypeLess veröffentlichen & Schlüssel sichern

## Eine neue Version veröffentlichen

1. `VERSION` anheben (z. B. `0.4.0` → `0.4.1`). **Einzige** Versionsquelle.
2. `bash scripts/release.sh --dry-run` — baut, packt, signiert, zeigt den Appcast-Eintrag,
   veröffentlicht **nichts**. Kurzkontrolle.
3. `bash scripts/release.sh` — baut, packt, EdDSA-signiert, ergänzt `appcast.xml`, lädt das Zip als
   GitHub-Release hoch und pusht `appcast.xml`.
4. Installierte Apps melden das Update binnen eines Tages (oder sofort über „Nach Updates suchen …").

## Warum die Schlüssel heilig sind

- **Code-Signing-Identität „TypeLess Dev"** (Schlüsselbund): macOS bindet Mikrofon-/
  Bedienungshilfen-/Eingabeüberwachungs-Rechte an diese Identität + die Bundle-ID
  `de.typeless.TypeLess`. Bleibt sie gleich, bleiben die Rechte über alle Updates erhalten.
- **Privater Sparkle-EdDSA-Schlüssel** (Schlüsselbund): signiert jedes Update. Nur Updates mit
  gültiger Signatur akzeptiert die installierte App.

## Sicherung (Pflicht)

Beide an einen sicheren Ort **außerhalb** des Repos (Passwortmanager oder verschlüsseltes Backup):

- `TypeLess Dev`-Zertifikat **inkl. Privatschlüssel** als passwortgeschützte `.p12`
  (Schlüsselbund → Exportieren).
- Privater EdDSA-Schlüssel: `generate_keys -x <datei>`.

## Auf einem neuen Build-Mac wiederherstellen

1. `.p12` doppelklicken → in den Schlüsselbund importieren (Identität „TypeLess Dev" ist zurück).
2. EdDSA-Privatschlüssel importieren: `generate_keys -f <datei>`.
3. `bash scripts/build-app.sh` signiert wieder mit „TypeLess Dev"; `release.sh` findet den
   EdDSA-Schlüssel.

## Bei Verlust

- **Code-Signing-Identität weg:** neue Identität → neue Designated Requirement → alle Macs müssen
  die Rechte **einmal neu** erteilen (Mikrofon/Bedienungshilfen/Eingabeüberwachung).
- **EdDSA-Schlüssel weg:** neuer Schlüssel → bereits installierte Apps akzeptieren das nächste
  Update **nicht** mehr als vertraut → dort einmalig neu installieren.

Deshalb: sichern, bevor die erste Version an andere Macs geht.
```

- [ ] **Step 7: Commit**

```bash
git add scripts/build-app.sh scripts/release.sh docs/RELEASE.md .gitignore apps/macos/sparkle_public_key.txt
git commit -m "M8-Verteilung Teil3: GitHub-Repo-Anbindung, echte Feed-URL, RELEASE.md + Schluessel-Sicherung

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Abnahme — frische Installation und Update-Durchlauf (Handprobe)

Der eigentliche Beweis von Teil 3. Kein Unit-Test kann den echten Sparkle-Update-Mechanismus ersetzen; diese Handprobe ist die Definition-of-Done. Sie läuft auf echter Hardware (idealerweise zweiter Mac oder frisches macOS-Benutzerkonto).

**Files:** keine (Abnahme). Ergebnis wird im Ledger/Report festgehalten.

- [ ] **Step 1: Version v_a veröffentlichen**

```bash
# VERSION steht auf z. B. 0.4.0
bash scripts/release.sh
```
Expected: GitHub-Release `0.4.0` mit `TypeLess-0.4.0.zip`; `appcast.xml` gepusht.

- [ ] **Step 2: Frische Installation von v_a**

Auf einem zweiten Mac **oder** in einem frischen macOS-Benutzerkonto (kein `uv`, kein Projektverzeichnis, keine erteilten Rechte): das Zip aus dem GitHub-Release laden, `TypeLess.app` nach `/Applications`, per Rechtsklick→Öffnen starten. Rechte erteilen. Warten, bis die Einrichtung (Python-Umgebung + Modelle) „ready" meldet und ein Diktat funktioniert.
Expected: Erststart läuft bis zum funktionierenden Diktat.

- [ ] **Step 3: Version v_b veröffentlichen**

```bash
# VERSION auf 0.4.1 anheben
bash scripts/release.sh
```
Expected: GitHub-Release `0.4.1`; `appcast.xml` enthält jetzt `0.4.1` **und** `0.4.0`.

- [ ] **Step 4: Update v_a → v_b in der laufenden Installation**

In der auf dem Test-Mac laufenden v_a: Menü → „Nach Updates suchen …".
Expected: Sparkle bietet `0.4.1` an (Dialog kommt sichtbar nach vorn), Download (~44 MB), Installation, Neustart der App.

- [ ] **Step 5: Erhalt nachweisen (der Kern der Abnahme)**

Nach dem Update prüfen:
- **Version:** Menü/`Info.plist` zeigt `0.4.1`.
- **Berechtigungen:** **kein** erneuter Rechte-Dialog; Diktat mit direktem Einfügen funktioniert sofort (belegt, dass Mikrofon/Bedienungshilfen/Eingabeüberwachung erhalten blieben).
- **Modelle:** das erste Diktat nach dem Update lädt **keine** Modelle neu (kein Einrichtungs-Fenster, sofort einsatzbereit) — `~/Library/Application Support/TypeLess/models` unverändert.

Expected: alle drei bestätigt. Ergebnis (bestanden/Befund) im Ledger festhalten. Dies schließt M8-Verteilung ab.

---

## Selbst-Review (gegen die Spec)

**Spec-Abdeckung:**
- Baustein A (Sparkle-Integration) → Tasks 3 + 4. ✅
- Baustein B (EdDSA) → Task 4 Step 1 (erzeugen) + Task 5 (`sign_update`) + Task 6 (sichern). ✅
- Baustein C (`release.sh` + Appcast, Version aus einer Quelle, Dry-Run/Idempotenz) → Tasks 1, 2, 5. ✅
- Baustein D (GitHub-Repo, Schlüssel-Sicherung, `RELEASE.md`) → Task 6. ✅
- Testing-Strategie (Appcast-Unit, Dry-Run, Version-Einzelquelle, Handproben-Abnahme) → Tasks 2, 5, 1, 7. ✅
- LSUIElement-Aktivierung des Update-Dialogs → Task 4 (Controller + Delegate). ✅
- „TypeLessCore bleibt Sparkle-frei" → Sparkle nur im App-Target (Task 3 Package.swift). ✅

**Bewusste Abweichung von der Spec-Grobreihenfolge:** Die Spec listet „EdDSA/Info.plist" (2) vor „Sparkle" (3). Umgekehrt umgesetzt, weil Sparkles `generate_keys`/`sign_update` erst nach der Sparkle-Dependency existieren. Inhaltlich identisch, nur die Reihenfolge dreht sich.

**Platzhalter-Scan:** `PLACEHOLDER_GH_USER`/`<user>` und `PLACEHOLDER_ED_PUBLIC_KEY` sind **bewusste**, im Text als „in Task 6 zu ersetzen" markierte Platzhalter (der echte Benutzername/Schlüssel steht erst nach dem Repo-/Schlüssel-Setup fest) — kein unspezifiziertes „TBD".

**Typ-/Namenskonsistenz:** `upsert_item(...)`-Signatur identisch in Task 2 (Definition), Test und `release.sh`-Aufruf. `UpdaterController` / `checkForUpdates()` konsistent über Tasks 3–5. `VERSION`/`SUFeedURL`/`SUPublicEDKey`/`SUScheduledCheckInterval` konsistent über Tasks 1, 4, 5, 6.

**Risiko:** Die Sparkle-Bundle-Einbettung (Task 3) ist der Spike; deshalb früh, mit hartem Go/No-Go (Signatur-Verify + dyld-Start) vor allem, was darauf aufbaut.
