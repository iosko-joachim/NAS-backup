# Bekannte Probleme — FRITZ!Box NAS & SMB

Sammlung der beim Entwickeln/Testen aufgetretenen Probleme rund um SMB, libsmb2 und die
FRITZ!Box-NAS — mit Symptom, Ursache und Status. Hilfreich vor allem zur Ferndiagnose über
das App-Protokoll (`NASBackup.log` → „Protokoll teilen").

---

## 🔴 OFFEN: FRITZ!Box-Verbindung scheitert mit „Operation not permitted" (EPERM)

**Symptom (aus dem Protokoll):**
```
smb2: Read from socket failed, errno:9. Closing socket.
Verbindungstest FEHLER: NSPOSIXErrorDomain 1 | Error code Operation not permitted:
```
Tritt auf manchen Geräten beim Verbinden zur realen FRITZ!Box auf — **obwohl die
Files-App mit denselben Zugangsdaten funktioniert** und der Schalter „Lokales Netzwerk"
laut Nutzer aktiv ist.

**Einordnung:** `errno 9` (EBADF) + `EPERM` ist die typische Signatur, dass **iOS den
rohen Socket der App killt** — die **Local-Network-Privacy-Durchsetzung**. Files läuft über
Apples privilegierten SMB-Pfad und ist davon nicht betroffen; unsere App nutzt **libsmb2 mit
rohen BSD-Sockets**.

**Mögliche Ursachen / Verdächtige:**
- Local-Network-Berechtigungsstatus **hängt/korrupt** (häufig nach mehreren
  Installations-/Lösch-Zyklen) — Schalter zeigt „an", Zugriff wird dennoch verweigert.
- **VPN**, **Sperrmodus (Lockdown Mode)**, **Content-/Werbeblocker** oder ein
  **Konfigurationsprofil** fängt den Socket ab (ebenfalls EPERM).

**Aktuelle Gegenmaßnahmen:**
- App **löschen → iPhone neu starten → aus TestFlight neu installieren →** beim ersten
  Start „Lokales Netzwerk" **erlauben** (Neustart räumt einen hängenden Status auf).
- VPN / Sperrmodus / Blocker prüfen und testweise deaktivieren.

**Noch zu klären / mögliche App-seitige Lösung:** Verbindung künftig über
**Network.framework (`NWConnection`)** statt roher Sockets aufbauen bzw. das Socket-Handle an
libsmb2 übergeben, damit der Zugriff sauber mit der iOS-Local-Network-Privacy integriert.
Ein Kontrolltest gegen Standard-Samba (mit erteilter Erlaubnis) verbindet erfolgreich — die
App-Logik an sich funktioniert.

---

## 🟡 IN ARBEIT: SMB-Signing / Dialekt-Aushandlung libsmb2 ↔ FRITZ!Box

FRITZ!OS (internes Samba) ist bei der SMB-Aushandlung strenger als manche NAS. AMSMB2-Default
war Signing „enabled"; ab Build 8 erzwingt der gepatchte `initClient` **Signing = required**.
libsmb2 meldet relevante Fälle selbst, u. a.:
- `Signing required by server. Session ...`
- `Encryption requested but server ...`

Ob Signing=required allein reicht, ist noch offen (überlagert vom EPERM-Thema oben). Weitere
Stellschraube: Dialekt auf **SMB 3.x / 3.1.1** erzwingen (`smb2_set_version`).

---

## 🟢 GELÖST: Verschachtelte Verzeichnisse wurden nicht angelegt

**Symptom:** Upload scheiterte mit „No such file or directory"; die zweite Verzeichnisebene
(`ziel/ordner_datum/`) wurde nie erstellt — auffällig nur, wenn der Zielordner bereits
existierte.

**Ursache:** `createDirectory` auf einem **bereits existierenden** Ordner liefert
`STATUS_OBJECT_NAME_COLLISION`. Dieser Fehler bringt libsmb2 so aus dem Tritt, dass die
**nachfolgende** Operation (tiefere Ebene) nicht mehr gesendet wird.

**Fix:** Beim rekursiven Remote-Listing (`SMBSession.snapshot`) werden **vorhandene
Verzeichnisse** miterfasst (`RemoteSnapshot.directories` + `baseExists`) und der
Verzeichnis-Cache damit vorbefüllt. `ensureDirectory` legt dann **nur wirklich fehlende**
Ebenen an — keine Kollision, kein vorheriger stat-Aufruf (der mit „not found" denselben
Effekt hätte).

---

## 🟢 ENTSCHEIDUNG: Äquivalenzkriterium = Größe (zeitzonensicher)

**Problem (Zeitzone / DST / FAT):** Der bisherige Inkrementell-Vergleich nutzt **mtime**
(„kopieren, wenn Quelle neuer"). Das ist **nicht verlässlich**, weil die Quell-mtime nicht
garantiert in der Vergangenheit liegt und vor allem **FAT/exFAT Zeitstempel als lokale
Wanduhrzeit ohne Zeitzone** speichert. Beim Zurücklesen über SMB/FTP entsteht je nach
**Sommer-/Winterzeit** oder Server-Zeitzone ein Versatz von **±1 (ganzen) Stunde(n)** → die
Quelle erscheint dauerhaft „neuer" → **dieselbe, unveränderte Datei wird bei jedem Lauf neu
kopiert**. (NTFS speichert UTC, dort tritt's nicht auf — darauf kann man sich aber nicht
verlassen. Die FREECOM-Platte an der FRITZ!Box ist vermutlich FAT/exFAT.) robocopy kennt das
Problem und hat dafür `/FFT` und `/DST`.

**Optionen:**
- **A) Größe als entscheidendes Kriterium (gewählt):** kopieren, wenn **fehlt ODER andere
  Größe**; bei **gleicher Größe → überspringen**. Zeitzonen-immun, einfach, für Backups ideal.
  Nachteil: in-place-Bearbeitung mit *exakt gleicher Größe* wird nicht erkannt (in der Praxis
  vernachlässigbar).
- **B) mtime mit offset-absorbierender Toleranz** (robocopy-`/FFT`-Stil): „neuer" nur werten,
  wenn der Unterschied **kein glattes Vielfaches von ~1 Stunde** ist. → optionaler „strenger
  Modus" (Standard aus).
- **C) Anomalie-Logging:** Quell-mtime in der Zukunft (relativ zur Geräteuhr) oder
  Stunden-Versatz Quelle/Ziel → **Warn-Log** („möglicher Zeitzonen-/DST-/FAT-Effekt"), damit
  das Verhalten sichtbar ist statt still in eine Re-Copy-Schleife zu laufen.

**Entscheidung (2026-06-06):** **A als Default.** B als optionaler strenger Modus, C immer als
Log. Gilt für SMB **und** FTP gleichermaßen (bei FTP entfällt der mtime-Ärger im Default
ohnehin; Größe via `SIZE`/`MLSD`). Ersetzt das bisherige `decide()`-Kriterium (Pfad+Größe+mtime).

---

## 🟡 WORKAROUND: Gast-Zugriff wird abgelehnt („Error code 1" / EACCES)

**Symptom:** Mit leerem Benutzer (→ App nutzt `guest`) lehnt Samba/FRITZ!Box den Login ab.

**Ursache:** libsmb2 macht eine **NTLM-Anmeldung als Benutzer „guest"**; modernes Samba lehnt
das ab (Default `map to guest = Never`), während es anonyme Sessions über `guest ok` zulässt.
macOS verbindet als anonyme NULL-Session und kommt damit durch.

**Workaround / Realität:** **Echten Benutzer** verwenden. Die **FRITZ.NAS verlangt ohnehin**
einen FRITZ!Box-Benutzer mit aktiviertem **„Zugang zu NAS-Inhalten"** — Gast ist also kein
praxisrelevanter Fall.

---

## 🔵 HINWEIS: „No route to host" (errno 65) = falsches Netz

iPhone und NAS müssen im **selben Subnetz** sein. Erscheint `No route to host (65)`, hängt das
iPhone in einem anderen WLAN/Subnetz (z. B. Mac-Hotspot 192.168.2.x statt Lab-Netz
192.168.0.x). Bei Stefans realem Einsatz unkritisch, da iPhone und FRITZ!Box ohnehin im
selben Heimnetz (192.168.178.x) sind.

---

## 🔵 HINWEIS: Test-Server (impacket) ≠ echtes Samba

Zum lokalen Testen diente zeitweise `impacket smbserver`. Eigenheiten, die **nur** am
Test-Server lagen (echtes Samba/FRITZ!Box verhalten sich korrekt):
- **mtime wird nicht persistiert** (`SetInfo` ignoriert) → Dateien bekamen „jetzt" als Datum.
- Die fehlerhafte `SetInfo`-Antwort löste **Reconnect-Schleifen** aus.
- `createDirectory` auf existierenden Ordnern wird toleriert (maskiert das Kollisionsproblem oben).

---

## Geplante Robustheit & Design-Entscheidungen (Diskussion 2026-06-06)

Reihenfolge: **erst Permission/Robustheit, dann Transport-Abstraktion, dann FTP.** Begründung:
Der aktuelle Blocker (iOS-Local-Network-EPERM) trifft **jede** LAN-Verbindung — FTP umgeht ihn
**nicht**.

- **Kein Resume-Manifest.** Verworfen — das **Äquivalenzkriterium ist bereits der Resume**:
  eine abgebrochene Datei hat eine andere Größe → wird neu kopiert; fertige werden
  übersprungen. (Siehe Entscheidung „Äquivalenzkriterium = Größe" oben.)
- **Pre-Flight = aktiver Probe-Connect + Klartext-Diagnose.** Wichtig: iOS bietet **keine API**,
  um den „Lokales Netzwerk"-Schalter auszulesen. Daher **Realität messen** (Test-Verbindung,
  am besten via `NWConnection`, das sich sauber mit der Local-Network-Privacy verzahnt **und**
  den Dialog triggert) und aus dem Ergebnis die Lage ableiten: erreichbar+erlaubt / blockiert
  (EPERM) / kein Netz (65) / Login / Freigabe / Schreibtest. Daraus eine **handlungsleitende**
  Meldung, z. B.: „Lokaler Netzwerkzugriff wird blockiert. Falls der Schalter auf AN steht,
  hängt der Status → App löschen, Gerät neu starten, neu installieren, erlauben."
- **Transport-Abstraktion** (`RemoteTransport`-Protokoll): `connect/snapshot/ensureDirectory/
  upload/setModificationDate/disconnect`. `SMBSession` erfüllt das fast 1:1; `BackupEngine`
  spricht nur noch das Protokoll an. Grundlage für FTP.
- **FTP als zweiter Transport (Fallback).** Kein natives iOS-FTP (CFFTPStream deprecated) →
  **libcurl** (FTP/FTPS, Upload+Progress, `MLSD`-Listing, `MFMT` für mtime). Eigenschaften:
  - **Kein „Share"-Begriff** → eigener Parameter-Dialog (Host, Port, FTPS-Modus, Passiv).
  - **Plain FTP erlaubt** (Heimnetz, vorerst); **FTPS** optionaler Schalter, **muss gegen die
    FRITZ!Box getestet werden** (FTPS im LAN evtl. nicht verfügbar — historisch nur am
    Internet-Zugang).
  - Größen/mtime-Lesen via `SIZE`/`MDTM`/`MLSD`; `MFMT` (mtime setzen) nur „nice to have".
  - Mehr Overhead bei sehr vielen kleinen Dateien (gut loggen).
  - **Umgeht das Local-Network-Gate NICHT.**
- **UI:** Protokoll-Picker (SMB/FTP) + gemeinsame Felder (Host, Benutzer, Passwort, Zielordner)
  + protokollspezifischer Abschnitt (SMB: Freigabe/Domain/Signing; FTP: Port/FTPS/Passiv).
- **Mehr Logs:** Log-Level + „Diagnose-Modus"-Schalter; Pre-Flight-Report (App-/iOS-Version,
  IP/Subnetz, Protokoll, Host/Freigabe/Benutzer ohne Passwort); libsmb2 `smb2_set_log_level`
  höher; „Diagnose senden" (Log + anonymisierte Config).
- **Weitere Robustheit:** Stall-Erkennung (kein Fortschritt → reconnect); Edge-Cases klar
  loggen + weiter (Datei > 4 GB auf FAT, Sonderzeichen/Pfadlängen); optionales Verify (Größe).

---

## Protokoll lesen — errno-/Meldungs-Spickzettel

| Meldung im Log | Bedeutung |
|---|---|
| `No route to host (65)` | Falsches Netz/WLAN — iPhone nicht im NAS-Subnetz |
| `Operation not permitted (1)` / `Permission denied (13)` / `Read from socket failed, errno:9` | iOS blockt den Socket → Lokales-Netzwerk-Berechtigung / VPN / Sperrmodus / Filter |
| `Session setup failed with (0x…)` | SMB-Anmeldung fehlgeschlagen — Benutzer/Passwort/NAS-Berechtigung |
| `Signing required by server` | Server verlangt SMB-Signing |
| `… bad network name …` | Falscher Freigabename (Tree-Connect) |
| `Verbindung erfolgreich` | 🎉 |

## FRITZ!Box-SMB — Konfigurationshinweise

- **Server** = IP der FRITZ!Box (`192.168.178.1`), **Freigabe** = der Laufwerksname
  (z. B. `FREECOM_HDD`). Der Gerätename (z. B. `FB6490SO`) ist **kein** Pfad-Bestandteil.
- FRITZ!Box-Oberfläche: **Heimnetz → USB/Speicher → Zugriff über SMB** aktivieren; Laufwerk freigeben.
- **FRITZ!Box-Benutzer** mit **„Zugang zu NAS-Inhalten"** (Lese/Schreib) verwenden — nicht Gast.
- SMB-Version „automatisch"; FRITZ!OS nutzt SMB2/3 (kein SMBv1).
