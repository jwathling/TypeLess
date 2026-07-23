# TypeLess veröffentlichen & Schlüssel sichern

> Stand: Der lokale Code für Selbst-Update (Sparkle) ist fertig. Das öffentliche GitHub-Repo und
> der Signier-Schlüssel sind noch NICHT eingerichtet — diese Anleitung führt beim Online-Gang durch
> beide Schritte. Bis dahin trägt die gebaute App einen Platzhalter-Update-Schlüssel und liefert
> keine echten Updates aus.

## Einmalig beim ersten Online-Gang

1. **EdDSA-Signier-Schlüssel erzeugen** (privater Teil landet im Schlüsselbund, öffentlicher in die App):
   ```bash
   GEN="$(find apps/macos/.build -name generate_keys -type f -perm -u+x | head -1)"
   "$GEN"                                   # erzeugt den privaten Schlüssel im Schlüsselbund (einmalig)
   "$GEN" -p > apps/macos/sparkle_public_key.txt   # öffentlichen Schlüssel in die App-Datei
   ```
2. **Öffentliches Repo anlegen und pushen:**
   ```bash
   gh auth status || gh auth login
   gh repo create TypeLess --public --source=. --remote=origin --push
   ```

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

## Sicherung (Pflicht, sobald der Schlüssel erzeugt ist)

Beide an einen sicheren Ort **außerhalb** des Repos (Passwortmanager oder verschlüsseltes Backup):

- `TypeLess Dev`-Zertifikat **inkl. Privatschlüssel** als passwortgeschützte `.p12`
  (Schlüsselbund öffnen → „TypeLess Dev" → Rechtsklick → Exportieren → .p12, Passwort vergeben).
- Privater EdDSA-Schlüssel: `generate_keys -x <datei>` (die Datei danach an den sicheren Ort bringen,
  NICHT ins Repo — `.gitignore` schützt `typeless-sparkle-private-key.txt` und `*.p12`).

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
