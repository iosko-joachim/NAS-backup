# Changelog

Alle Builds laufen unter Version **1.0**; die Build-Nummer (`CURRENT_PROJECT_VERSION`)
wird je TestFlight-Upload hochgezählt. Die frühen Builds waren schnelle TestFlight-Iterationen.

## 1.0 (Build 8) — aktuell

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
