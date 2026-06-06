# Bekannte Probleme — FRITZ!Box NAS & SMB

Sammlung der beim Entwickeln/Testen aufgetretenen Probleme rund um SMB, libsmb2 und die
FRITZ!Box-NAS — mit Symptom, Ursache und Status. Hilfreich vor allem zur Ferndiagnose über
das App-Protokoll (`NASBackup.log` → „Protokoll teilen").

---

## 🟢 GEKLÄRT: SMB scheitert mit „Operation not permitted" (EPERM) — iOS blockt rohe Sockets

**Symptom (aus dem Protokoll):**
```
Verbindungstest Pre-Flight: ok — Netzwerkweg frei.        <- NWConnection-Probe gelingt!
smb2: Read from socket failed, errno:9. Closing socket.    <- libsmb2-Rohsocket
Verbindungstest FEHLER: NSPOSIXErrorDomain 1 | Error code Operation not permitted:
```

**Beweisführung (Build 9/10, iOS 18.7.8):** Der **Pre-Flight über `NWConnection` ist `ok`** —
und NWConnection unterliegt **derselben** „Lokales Netzwerk"-Berechtigung. Wäre die Erlaubnis
nicht erteilt, würde **auch der Pre-Flight** blockiert. Er gelingt aber. **→ Die Berechtigung
IST erteilt.** Trotzdem bekommt **libsmb2 (rohe BSD-Sockets) EPERM**.

**Erkenntnis:** Auf **modernem iOS (≥ 18.7)** erlaubt das System **Network.framework
(NWConnection)**, blockt aber **rohe BSD-Sockets** fürs lokale Netz — **selbst bei erteilter
Berechtigung**. Es war also nie Gast/Signing/Schalter/VPN, sondern diese Socket-Einschränkung.
(Auf älteren iOS-Versionen lief libsmb2 noch — z. B. der 922-Dateien-Test.)

**Lösung: FTP statt SMB.** Der FTP-Transport (`FTPSession`) läuft über **NWConnection** und ist
damit nicht betroffen — er verbindet und kopiert auf genau dem Gerät, auf dem SMB scheitert
(in Stefans Tests bestätigt). **SMB via libsmb2 ist auf modernem iOS für lokale Netze faktisch
eine Sackgasse.**

**Offen/optional:** SMB über NWConnection tunneln (Socket-Handle an libsmb2 übergeben) — großer
Aufwand, nur falls SMB zwingend nötig wird. Pragmatisch: **FTP nutzen.** Mögliche UX-Politur:
bei genau dieser SMB-Signatur automatisch „→ bitte auf FTP umschalten" anzeigen; ggf. FTP als
Standardprotokoll.

> Hinweis: Das frühere „🟡 IN ARBEIT: SMB-Signing"-Thema ist damit **gegenstandslos** — der
> Abbruch passiert auf Socket-Ebene, lange vor der SMB-Aushandlung. Signing/Dialekt waren nicht
> die Ursache.

---

## 🟢 FTP: funktioniert (NWConnection) — Eigenheiten der FRITZ!Box

FTP ist auf modernem iOS der **zuverlässige** Transport. FRITZ!Box-spezifische Punkte:

- **Kein MLSD:** FRITZ!Box-FTP beantwortet `MLSD` mit `500`. Ab **Build 11** schaltet die App
  automatisch auf **`LIST`** um (Unix-`ls -l`-Parser, liest Größe/Typ inkl. Namen mit
  Leerzeichen) → Snapshot, Inkrementell-Abgleich und NAS-Browser funktionieren.
- **Kein MFMT:** `MFMT` (mtime setzen) → `500`. Ab Build 11 nach dem ersten 5xx dauerhaft
  abgeschaltet. Unkritisch, da Vergleich über die **Größe** läuft.
- **Pfadstruktur / „kein Share-Feld" bei FTP:** FRITZ!Box-Pfad ist
  `IP / Share (FB6490SO) / Ordner (FREECOM_HDD) / …`. Bei FTP gibt es **kein Share-Feld** — der
  **komplette Pfad ab FTP-Wurzel** gehört in den **Zielordner**. **Kein `chdir` nötig:** die
  FRITZ!Box akzeptiert mehrstufige Pfade (`MKD a/b/c ⇐ 257`); die App legt exakt den
  übergebenen Pfad an. Fehler „landet im Halbleiterspeicher statt auf der Platte" = Zielpfad war
  unvollständig (`FB6490SO` statt bis `…/FREECOM_HDD/IP13`). **Lösung:** Host = **nur die IP**,
  Zielordner leeren, **„Auf dem NAS auswählen"** → bis `FREECOM_HDD` navigieren → `IP13`
  anlegen/wählen. Der Browser baut den vollständigen Pfad.

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

---

## 🔵 Fernzugriff aufs NAS via VPN (Test über Distanz)

    **Kontext:** Das Test-NAS (FRITZ!Box) steht ~300 km entfernt. Um die echte Box zu
    erreichen/zu testen, ohne vor Ort zu sein, bietet sich ein VPN ins Heimnetz an.

    **Lösung:** Die FRITZ!Box bringt VPN selbst mit:
    - FRITZ!OS 7.50+ → **WireGuard** (einfachste Variante): auf der Box einen VPN-Zugang
      anlegen, Konfiguration exportieren, auf dem iPhone in der WireGuard-App / den iOS-
      VPN-Einstellungen importieren.
    - Ältere Firmware → IPSec / „FRITZ!Fernzugang".

    Danach ist das iPhone logisch in Stefans Heimnetz (192.168.178.x) und erreicht die NAS
    unter `192.168.178.1`, als wäre man vor Ort. SMB (TCP/445) läuft durch den Tunnel.

    **Wofür VPN geeignet ist:**
    - SMB-/Erreichbarkeits-Tests gegen die **echte** FRITZ!Box (Login, Signing/Dialekt,
      Freigabename) — isoliert vom Local-Network-Thema.
    - Latenz/Bandbreite über die Distanz stören beim Testen nicht (nur ein 10-GB-Vollbackup
      wäre langsam).

    **Wichtiger Haken (Local Network):**
    VPN-Verkehr läuft über ein Tunnel-Interface (utun) und gilt für iOS i. d. R. **nicht** als
    „lokales Netzwerk". Damit wird die **iOS-Local-Network-Berechtigung** (der vermutete
    EPERM-Blocker) über VPN evtl. gar nicht ausgelöst bzw. greift anders. Folgen:
    - Ein **Erfolg über VPN beweist NICHT**, dass die direkte lokale Verbindung (ohne VPN,
      iPhone im Heim-WLAN) funktioniert.
    - Das Local-Network-Permission-Problem muss am Ende trotzdem auf dem **lokalen** Weg
      (ohne VPN) verifiziert werden — VPN umgeht diese Hürde, statt sie nachzustellen.

    **Fazit:** VPN (FRITZ!Box-WireGuard) ist gut, um die **SMB-Seite** gegen die reale Box zu
    klären; das **Local-Network-Thema** bleibt separat lokal zu prüfen.
