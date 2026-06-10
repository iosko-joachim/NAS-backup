# NAS Backup (iOS)

Eine native iOS-App (SwiftUI), die — robocopy-artig — einen oder mehrere Ordner aus
**„Auf meinem iPhone"** (Files) **rekursiv und inkrementell** per **SMB** auf ein NAS sichert.
Zielszenario: USB-Festplatte an einer **FRITZ!Box** (`192.168.178.1`, Freigabe z. B.
`FREECOM_HDD`).

Entstanden aus einer konkreten Anforderung: Der bisherige Workflow (Files → „Share to
Owlfiles") brach bei großen Mengen (~10 GB / 10.000 Dateien) unzuverlässig ab
(`Socket Error 32 [Broken pipe]`). NAS Backup macht denselben Job gezielt und robust.

> **Status:** Unterstützt **SMB und FTP** (umschaltbar). SMB end-to-end verifiziert (Standard-Samba
> 922 Dateien; lokaler FRITZ.NAS-Repro: opendir/mkdir/write/mtime, echter Backup-Lauf);
> FTP gegen pyftpdlib **und** an einer FRITZ!Box.
> **🟢 Gelöst (Build 20):** Das hartnäckige SMB-`STATUS_ACCESS_DENIED` (an Stefans FRITZ!Box und
> im lokalen Repro) war **kein NAS-Rechteproblem, sondern ein libsmb2-Signing-Bug**: libsmb2
> schickte unter SMB 3.1.1 die CREATE/opendir-PDUs **unsigniert**, sobald der Server Signing nur
> „enabled" (statt „required") meldet → Server verwirft sie. Fix: Signing client-seitig explizit
> erzwingen (`smb2_set_sign(1)`). Damit lesen **und** schreiben über SMB. (Frühere Annahmen „SMB
> auf iOS unmöglich" bzw. „Schreibrecht fehlt serverseitig" sind **widerlegt**.)
> Details: [ISSUES.md](ISSUES.md). Verteilung über **TestFlight** (aktuell Build 20).

## Funktionen

- **Mehrere Quellordner** auswählen (Security-Scoped Bookmarks, bleiben über Neustarts erhalten)
- **Rekursives, inkrementelles Kopieren** wie robocopy: nur fehlende, neuere oder
  größenverschiedene Dateien (Vergleich über Größe + Änderungsdatum)
- **Zeitstempel-Erhaltung** am Ziel (`SetInfo`), damit der Abgleich über Läufe stabil bleibt
- **Resilienz**: pro Datei bis zu 4 Versuche mit **Reconnect** (gegen „broken pipe"); ein
  Einzeldatei-Fehler bricht den Lauf nicht ab, sondern landet im Fehlerprotokoll
- **Interaktiver Ziel-Browser**: NAS durchsuchen, Ordner anlegen, „hier sichern"
- **Overlap-Dedup**: verschachtelte/doppelte Quellen werden zusammengeführt (nichts doppelt)
- **Quellordner entfernen** (neutrale „Entfernen"-Wischaktion — löscht keine Daten)
- **Bildschirm bleibt wach** während der Übertragung (`isIdleTimerDisabled`)
- **Datei-Protokoll** (`NASBackup.log`) inkl. echter libsmb2-Meldungen, in der Files-App
  sichtbar und per Share-Sheet teilbar
- **Versionsanzeige** auf dem Hauptbildschirm

## ⚠️ Wichtige iOS-Einschränkungen

- **Sperrbildschirm / Hintergrund:** Echtes Weiterkopieren bei gesperrtem Bildschirm ist
  auf iOS für SMB **nicht möglich** (Background-Transfers gibt es nur für HTTP via
  `URLSession`). Lösung: Bildschirm während des Transfers wachhalten; Gerät ans Ladegerät.
- **Lokales Netzwerk:** SMB läuft über das lokale Netz; iOS verlangt die Berechtigung
  „Lokales Netzwerk". libsmb2 nutzt rohe BSD-Sockets, die diesen Dialog nicht zuverlässig
  auslösen — die App stößt ihn daher aktiv über einen Bonjour-Browse an. Siehe ISSUES.md.

## Architektur

| Datei | Aufgabe |
|---|---|
| `NASBackup/Models/Models.swift` | `SMBConfig`, `SourceFolder`, `PlannedFile`, `RemoteSnapshot`, … |
| `NASBackup/Services/SMBSession.swift` | Wrapper um AMSMB2: connect/reconnect, Listing, mkdir, Upload+Progress, mtime |
| `NASBackup/Services/BackupEngine.swift` | Orchestrierung: Scan → Abgleich → Kopieren mit Retry/Reconnect |
| `NASBackup/Services/SettingsStore.swift` | Persistenz (UserDefaults + Bookmarks) |
| `NASBackup/Services/KeychainStore.swift` | Passwort im Keychain |
| `NASBackup/Util/LocalNetwork.swift` | Löst den iOS-„Lokales Netzwerk"-Dialog aus (Bonjour) |
| `NASBackup/Util/Log.swift` | Datei-Protokoll im Documents-Ordner |
| `NASBackup/Views/*` | SwiftUI: Start, Verbindung, NAS-Browser, Live-Fortschritt, Protokoll |
| `Vendor/AMSMB2/` | **Eingebettetes, gepatchtes** AMSMB2 (siehe unten) |

### Abhängigkeit: AMSMB2 (gepatcht, vendored)

[AMSMB2](https://github.com/amosavian/AMSMB2) wrappt **libsmb2** (wird aus C-Quellen
mitgebaut). Hier **lokal eingebunden** unter `Vendor/AMSMB2`, mit zwei Patches:

- **Signing = required** im Verbindungsaufbau (`initClient`) — viele gehärtete Server
  (FRITZ!Box) verlangen SMB-Signing.
- **`SMB2DebugLog`** + libsmb2-Error-Callback (`smb2_register_error_callback`): leitet die
  echten libsmb2-Fehlertexte an einen Host-Hook weiter → landen im App-Protokoll.

**Lizenz:** libsmb2 ist **LGPL-2.1**; das Framework wird **dynamisch** gelinkt (App-Store-konform).

## Bauen

Voraussetzungen: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
xcodegen generate          # erzeugt NASBackup.xcodeproj aus project.yml
open NASBackup.xcodeproj
```

CLI-Build (Simulator):

```bash
xcodebuild -project NASBackup.xcodeproj -scheme NASBackup \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

### TestFlight (Release-Archiv)

```bash
xcodebuild -project NASBackup.xcodeproj -scheme NASBackup \
  -destination 'generic/platform=iOS' \
  -archivePath build/NASBackup.xcarchive -allowProvisioningUpdates archive

xcodebuild -exportArchive -archivePath build/NASBackup.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates
```

Build-Nummer in `project.yml` (`CURRENT_PROJECT_VERSION`) hochzählen; die Info.plist nutzt
`$(CURRENT_PROJECT_VERSION)` / `$(MARKETING_VERSION)`. Anschließend `build/export/NASBackup.ipa`
per Transporter oder Xcode Organizer hochladen.

> **Hinweis Export-Compliance:** Setzt man `ITSAppUsesNonExemptEncryption = false` in die
> Info.plist, entfällt der Verschlüsselungs-Fragebogen — Apple verlängert dann aber die
> Verarbeitung deutlich (~13 min statt ~2 min). Ohne den Key: schnelle Verarbeitung, dafür
> Fragebogen je Build (Standard-Verschlüsselung → Ausnahme; Frankreich → Nein).

## Verteilung / Signing

- Bundle-ID: `de.jomative.nasbackup`, Team `XV75SD8TB6` (in `project.yml` anpassbar)
- Verteilung über **TestFlight** (Apple Developer Account erforderlich)
- `NASBackup.xcodeproj` ist **generiert** und nicht eingecheckt — `project.yml` ist die Quelle.

## Dokumente

- [CHANGELOG.md](CHANGELOG.md) — Build-Historie
- [ISSUES.md](ISSUES.md) — FRITZ!Box-NAS- & SMB-Probleme (gelöst & offen)
