# Changelog

Alle Builds laufen unter Version **1.0**; die Build-Nummer (`CURRENT_PROJECT_VERSION`)
wird je TestFlight-Upload hochgezählt. Die frühen Builds waren schnelle TestFlight-Iterationen.

## 1.0 (Build 13) — aktuell

- **FTP-Diagnose beim Verbindungstest:** loggt das **Login-Verzeichnis (`PWD`)** und den
  **Inhalt der FTP-Wurzel**. Klärt, dass das FTP-Startverzeichnis sich vom Web-/SMB-Pfad
  unterscheiden kann, und zeigt, **ob die USB-Platte (z. B. `FREECOM_HDD`) im FTP-Baum
  auftaucht** — damit der richtige Zielpfad ohne Raten gefunden wird.

## 1.0 (Build 12)

- **Schnellabbruch bei dauerhaften FTP-Fehlern (5xx):** „Permission denied" (550/553) o. ä.
  werden NICHT mehr 4× mit Reconnect wiederholt — sofortiger, klarer Fehler statt Log-Spam.
- **Klartext-Hinweis bei „Permission denied":** Zielordner liegt vermutlich nicht auf der
  USB-Platte (sondern im internen FRITZ!Box-Speicher) **oder** der Benutzer hat keine
  NAS-Schreibrechte → Hinweis, per „Auf dem NAS auswählen" die Platte zu wählen + Rechte prüfen.
- **FTP-Hinweis in der UI:** Zielordner = voller Pfad ab FTP-Wurzel (z. B. `FREECOM_HDD/IP13`),
  am besten per Browser wählen; FRITZ!Box-Benutzer braucht NAS-Schreibrechte.

## 1.0 (Build 11)

- **FTP: LIST-Fallback**, wenn der Server kein **MLSD** kann (FRITZ!Box → 500). Damit
  funktionieren Snapshot/Inkrementell-Abgleich **und** der NAS-Browser auch an der FRITZ!Box.
  LIST-Parser (Unix-`ls -l`) liest Größe + Typ, inkl. Dateinamen mit Leerzeichen.
- **MFMT** nach erstem „nicht unterstützt" (5xx) dauerhaft abschalten — spart Round-Trips/Log;
  Größen-Kriterium bleibt korrekt.
- NAS-Browser fällt bei ungültigem gespeichertem Zielpfad automatisch auf die Wurzel zurück
  (z. B. nach Protokollwechsel SMB→FTP), damit man von oben navigieren kann.
- Verifiziert gegen FRITZ!Box-ähnlichen FTP-Server (MLSD/MFMT deaktiviert).

## 1.0 (Build 10)

- **FTP-Unterstützung** (`FTPSession`) über **Network.framework / NWConnection** — bewusst
  NICHT libcurl/rohe Sockets: der NWConnection-Pfad ist Apple-Privacy-integriert (saubere
  Local-Network-Erlaubnis). Plain FTP (passiv, MLSD/STOR/MKD/MFMT); FTPS-Schalter vorerst
  geblockt. Gegen pyftpdlib end-to-end verifiziert (connect, rekursives Listing, mkdir,
  Upload, mtime).
- **Transport-Abstraktion `RemoteTransport`** + `TransportFactory`; `SMBSession` und
  `FTPSession` sind austauschbare Implementierungen. Engine/Views sprechen nur das Protokoll.
- **Protokoll-Umschalter (SMB/FTP)** in der UI + protokollspezifische Felder (SMB: Freigabe/
  Verschlüsselung; FTP: Port/Passiv/FTPS). `TransferConfig` ersetzt `SMBConfig`.

## 1.0 (Build 9)

- **Äquivalenzkriterium = Dateigröße** (zeitzonensicher): kopieren nur bei fehlend/anderer
  Größe; gleiche Größe → überspringen. mtime nur für optionalen strengen Modus + Anomalie-Log.
- **Strenger Zeitvergleich** als Schalter (Standard aus); ignoriert glatte Stunden-Offsets
  (DST/Zeitzone/FAT).
- **Pre-Flight** (aktiver `NWConnection`-Probe vor Transfer + im Verbindungstest): klare
  Diagnose (blockiert/kein Netz/abgelehnt/Timeout) statt „Error 1"; Umgebungs-Report im Log.

## 1.0 (Build 8)

- **AMSMB2 lokal eingebunden & gepatcht** (`Vendor/AMSMB2`):
  - SMB-**Signing = required** im Verbindungsaufbau (gehärtete Server / FRITZ!Box).
  - **`SMB2DebugLog`** + `smb2_register_error_callback`: echte libsmb2-Fehlertexte
    (z. B. „Session setup failed (0x…)", „Read from socket failed, errno:…") werden ins
    App-Protokoll geschrieben — statt nur „Error code 1".
- Diagnose damit deutlich präziser (unterscheidet Netz/Berechtigung/SMB sauber).

## 1.0 (Build 7)

- Export-Compliance-Key wieder entfernt → **schnelle App-Store-Connect-Verarbeitung**
  (~2 min statt ~13 min). Dafür Verschlüsselungs-Fragebogen je Upload.

## 1.0 (Build 6)

- **Datei-Protokoll** `NASBackup.log` (Documents-Ordner), in der Files-App sichtbar
  (`UIFileSharingEnabled`), mit **„Protokoll teilen"** und **„Protokoll löschen"**.
- Loggt App-Start, Verbindungstests (inkl. Fehlertext), Backup-Start, Datei-Fehler, Abschluss.
- `ITSAppUsesNonExemptEncryption = false` (Build 6 only) → kein Verschlüsselungs-Fragebogen.

## 1.0 (Build 4)

- **Versionsanzeige** auf dem Hauptbildschirm („NAS Backup 1.0 (Build N)").

## 1.0 (Build 3) — Local-Network-Fix

- **`NSBonjourServices` + aktiver Bonjour-Browse** (`LocalNetwork.requestPermission`), um den
  iOS-Dialog „Lokales Netzwerk" zuverlässig auszulösen (libsmb2 nutzt rohe Sockets, die ihn
  sonst nicht triggern).

## 1.0 (Builds 1–2) — erste TestFlight-Builds

- **App-Icon** ergänzt (Asset-Katalog, 1024 px ohne Alpha) — vorher Validierungsfehler 409.
- **Eingebettetes AMSMB2-Framework** korrekt gebündelt + signiert (zuvor dyld-Crash auf dem
  Gerät, weil das dynamische Framework nicht eingebettet war).

## Vor TestFlight — Kernentwicklung

- SwiftUI-App, Swift 6.x, Ziel iOS 18+, Projekt via XcodeGen.
- SMB über AMSMB2/libsmb2; rekursiver, **inkrementeller** Kopiervorgang (Größe + mtime),
  **mtime-Erhaltung**, **Reconnect + Retry pro Datei**, Bildschirm wachhalten.
- **Interaktiver NAS-Ziel-Browser** (navigieren, Ordner anlegen, „hier sichern").
- **Quellordner entfernen** als neutrale Wischaktion (löscht keine Daten).
- **Overlap-Dedup**: verschachtelte/doppelte Quellen werden zusammengeführt.
- **Bugfix Verzeichnis-Anlage:** `createDirectory` auf einem bereits existierenden Ordner
  liefert `STATUS_OBJECT_NAME_COLLISION` und brachte libsmb2 so aus dem Tritt, dass tiefere
  Ebenen nicht mehr angelegt wurden. Fix: existierende Verzeichnisse beim Listing erfassen
  (`RemoteSnapshot`) und nur fehlende anlegen. Siehe [ISSUES.md](ISSUES.md).
- End-to-End gegen Standard-Samba verifiziert: 922 Dateien / 175 Ordner, Zeitstempel erhalten,
  zweiter Lauf überspringt alles.
