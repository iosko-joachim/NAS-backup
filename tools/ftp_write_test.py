#!/usr/bin/env python3
"""Mini-PoC: Kann der FRITZ!Box-FTP auf die USB-Platte SCHREIBEN — oder nur lesen?

Vergleicht einen Schreibversuch auf der USB-Platte (z. B. FREECOM_HDD) mit einem
Schreibversuch in die FTP-Wurzel (interner FRITZ!Box-Speicher) als Kontrolle und
gibt ein klares Urteil aus. Muss in Stefans WLAN laufen (gleiches Netz wie die Box).

  python3 ftp_write_test.py --host 192.168.178.1 --user nasbackup --dir FREECOM_HDD

Jeder gesendete FTP-Befehl wird als `ftp> CMD  ⇐ Antwort` protokolliert (plus die
rohe ftplib-Debug-Ausgabe `*cmd*/*resp*`), damit man die Befehle notfalls in einem
beliebigen FTP-Client von Hand absetzen kann. Nur Python-Standardbibliothek.
"""
import argparse
import ftplib
import getpass
import io


def cmd(ftp: ftplib.FTP, command: str) -> str:
    """Sendet einen Kontroll-Befehl, protokolliert ihn als `ftp> …  ⇐ …`."""
    print("ftp>", command)
    try:
        resp = ftp.sendcmd(command)
        print("     ⇐", resp)
        return resp
    except ftplib.all_errors as e:
        print("     ⇐", e)
        raise


def attempt_write(ftp: ftplib.FTP, base: str) -> bool:
    label = base if base else "(FTP-Wurzel / intern)"
    prefix = base.rstrip("/") + "/" if base else ""
    testdir = prefix + "__nasbackup_writetest__"
    testfile = testdir + "/probe.txt"
    print(f"\n=== Schreibtest in: {label} ===")
    try:
        cmd(ftp, "MKD " + testdir)
    except ftplib.all_errors:
        pass  # MKD darf scheitern (Ordner existiert evtl.) — STOR ist der eigentliche Test
    ok = False
    # storbinary macht intern PASV + STOR; mit Debuglevel 2 sind beide sichtbar.
    print("ftp> STOR", testfile)
    try:
        ftp.storbinary("STOR " + testfile, io.BytesIO(b"nasbackup ftp write test\n"))
        print("     ⇐ 226 Transfer complete  -> SCHREIBEN GEHT")
        ok = True
    except ftplib.all_errors as e:
        print("     ⇐", e, " -> SCHREIBEN VERWEIGERT")
    if ok:  # aufräumen
        for c in ("DELE " + testfile, "RMD " + testdir):
            try:
                cmd(ftp, c)
            except ftplib.all_errors:
                pass
    return ok


def print_manual_recipe(host: str, user: str, usb_dir: str) -> None:
    print("------------------------------------------------------------")
    print("Manuelle Entsprechung (falls Skript nicht läuft), in einem FTP-Client:")
    print(f"  open {host}        (Benutzer: {user}, dann Passwort)")
    print("  passive")
    print(f"  cd {usb_dir}       # USB-Platte")
    print("  put <lokale-datei> probe.txt    # <- hier 553/550 = nur lesen?")
    print("  cd /               # interner Speicher (Kontrolle)")
    print("  put <lokale-datei> probe.txt    # <- hier 226 = schreibbar")
    print("  delete probe.txt   # aufräumen, falls intern ging")
    print("  bye")
    print("------------------------------------------------------------")


def main() -> None:
    ap = argparse.ArgumentParser(description="FTP-Schreibtest USB-Platte vs. intern")
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=21)
    ap.add_argument("--user", required=True)
    ap.add_argument("--password")
    ap.add_argument("--dir", default="FREECOM_HDD",
                    help="Pfad der USB-Platte ab FTP-Wurzel (Default: FREECOM_HDD)")
    args = ap.parse_args()

    print_manual_recipe(args.host, args.user, args.dir)
    pw = args.password or getpass.getpass("FTP-Passwort: ")

    ftp = ftplib.FTP()
    ftp.set_debuglevel(2)  # zeigt JEDEN gesendeten Befehl (*cmd*) und jede Antwort (*resp*)
    print(f"\nVerbinde {args.host}:{args.port} …")
    ftp.connect(args.host, args.port, timeout=15)
    ftp.login(args.user, pw)   # sendet USER / PASS (im Debug sichtbar)
    ftp.set_pasv(True)
    cmd(ftp, "TYPE I")
    cmd(ftp, "PWD")
    print("Wurzel-Inhalt:", ftp.nlst())

    usb_ok = attempt_write(ftp, args.dir)   # USB-Platte
    root_ok = attempt_write(ftp, "")        # interner Speicher (Kontrolle)
    try:
        ftp.quit()
    except ftplib.all_errors:
        pass

    print("\n================ ERGEBNIS ================")
    print(f"USB-Platte ({args.dir}): {'SCHREIBEN GEHT' if usb_ok else 'NUR LESEN / verweigert'}")
    print(f"FTP-Wurzel (intern):     {'SCHREIBEN GEHT' if root_ok else 'verweigert'}")
    if root_ok and not usb_ok:
        print(">> These BESTÄTIGT: FTP bindet die USB-Platte NUR LESEND ein → SMB ist der Weg.")
    elif usb_ok:
        print(">> These WIDERLEGT: FTP kann auf die USB-Platte schreiben (Ursache lag woanders).")
    else:
        print(">> Unklar: auch intern kein Schreiben — Verbindung/Rechte prüfen.")


if __name__ == "__main__":
    main()
