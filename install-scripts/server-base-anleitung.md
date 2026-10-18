# server-base.sh – Debian-Basiseinrichtung

Stand: 18.10.2026. Für frische Debian-12/13-Server mit systemd, laufendem SSH-Dienst, Root-Zugang, apt-Paketquellen und Netzwerkzugang. Unabhängig von cloud-init; Bash, util-linux/flock und ssh-keygen werden vorausgesetzt. Unterstützt keine Plesk-/Proxmox-Bestandssysteme als pauschale Nachkonfiguration.

## Schlüssel vorbereiten

Der tatsächliche Public-Key wurde noch nicht bereitgestellt. Es ist kein fremder oder erfundener Schlüssel eingebaut.

Entweder die leere Variable `ADMIN_PUBLIC_KEY=''` am Anfang des Skripts mit dem eigenen öffentlichen Schlüssel in einer Zeile füllen oder eine Datei `ckAdmin.pub` neben das Skript legen. Alternativ `--key-file /root/ckAdmin.pub` angeben.

Erwartetes Format: `ssh-rsa AAAA... optionaler-Kommentar` (OpenSSH authorized_keys). Ein PuTTY-Public-Key im mehrzeiligen RFC4716-Format ist vorher in das OpenSSH-Format zu exportieren. Die private `.ppk`-Datei bleibt auf dem eigenen PC. RSA wird ab 2048 Bit akzeptiert; RSA erfordert keine Freischaltung veralteter SHA-1-Signaturen.

## Interaktiv als root starten

```bash
bash server-base.sh --key-file /root/ckAdmin.pub
```

1. Fingerabdruck mit dem eigenen Schlüssel vergleichen.
2. Das Skript richtet ckAdmin, das Home-Verzeichnis und den Schlüssel ein. sudo wird ohne Passwort erlaubt. Bestehende Schlüssel bleiben erhalten.
3. In einer zweiten PuTTY-Sitzung mit dem privaten Schlüssel als ckAdmin anmelden. Dort `sudo -n id -u` ausführen; erwartet wird `0`. Erst danach im Skript `TESTED` eingeben.
4. Das Skript schreibt `/etc/ssh/sshd_config.d/00-server-base.conf`, prüft Syntax und ausgewählte effektive Regeln und lädt SSH neu.
5. Eine weitere NEUE PuTTY-Verbindung als ckAdmin öffnen und den sudo-Test wiederholen. Anschließend im Skript `CONFIRM` eingeben.

Ab dann ist Root-SSH gesperrt. Passwort- und Keyboard-Interactive-Anmeldungen über SSH sind für alle Benutzer abgeschaltet; zugelassen ist Public-Key-Authentifizierung. Lokale Root-/Rettungskonsolen werden nicht gesperrt. SSH-Port und Firewall bleiben unverändert. Bestehende Benutzer werden nicht ausgeschlossen; deren Schlüsselzugänge bleiben grundsätzlich möglich.

## Optionale Varianten

```bash
# Zusätzlich reguläre Paketupgrades; keine automatische Paketentfernung:
bash server-base.sh --key-file /root/ckAdmin.pub --upgrade

# Hoster-Startfunktion ohne Terminal; Schlüsseldatei muss vorher vorhanden sein
# oder der öffentliche Schlüssel muss in ADMIN_PUBLIC_KEY stehen:
bash server-base.sh --unattended

# Anderen Benutzer oder andere Zeitzone wählen:
bash server-base.sh --key-file /root/admin.pub --admin-user admin --timezone UTC
```

Unbeaufsichtigt entfallen beide Login-Bestätigungen. Vorher in einer wegwerfbaren Debian-VM testen und Zugriff auf die Hoster-Rettungskonsole sicherstellen. Das Skript allein kann sich ohne Hoster-Startfunktion nicht beim ersten Boot ausführen. Nicht mit `curl ... | bash` starten; als Datei herunterladen und prüfen. Wenn ein Public-Key im Skript eingebettet ist, ist nur diese eine Datei zum Start erforderlich.

## Fehler und Wiederholung

Fehler nach Beginn der SSH-Umstellung, ein normaler Abbruch oder eine fehlende Abschlussbestätigung führen zur Wiederherstellung der vorherigen, vom Skript verwalteten SSH-Datei und zu einem Reload. Das ist kein zeitgesteuerter Rettungsmechanismus und wirkt nicht bei Stromausfall, SIGKILL oder beschädigtem Dateisystem. Benutzer, Pakete und erfolgreich eingerichtete sudo-Regeln bleiben erhalten. Backups liegen im ausgegebenen privaten Verzeichnis `/root/.server-base.*`.

Bei bestehendem Benutzer werden UID, Home und Bash geprüft; abweichende Bestandskonfigurationen führen zum Abbruch. Die sudo-Regel wird kontrolliert ersetzt, öffentliche Schlüssel werden anhand ihres Schlüsselmaterials ohne zusätzliche Duplikate ergänzt. Ein erneuter interaktiver Lauf fordert die Tests erneut an. Neue Schlüssel werden ergänzt; alte Schlüssel werden nicht automatisch widerrufen.

Die Prüfung effektiver SSH-Regeln umfasst root/ckAdmin für die aktuelle Client-IP (falls bekannt), IPv4-Loopback und IPv6-Loopback. Beliebige andere `Match`-Kontexte, Dienst-Startparameter und Netzwerkerreichbarkeit sind damit nicht vollständig geprüft. Die zwei echten Anmeldetests sind deshalb Bestandteil des Standardablaufs.

## Bewusst separater Umfang

Kein Swap, keine Firewalländerung, kein Docker, Portainer oder Webserver, keine fremde Root-bashrc und keine nächtlichen dist-upgrade-/Watchtower-Jobs. Automatische Sicherheitsupdates sind noch kein Bestandteil dieser Version. Basispakete: sudo, openssh-server, ca-certificates, curl, cron, mc, htop, tzdata. Der Standardlauf aktualisiert den Paketindex und installiert Basispakete; ein allgemeines Systemupgrade erfordert `--upgrade`.

## Prüfung dieser Fassung

Bash-Syntax und Hilfeaufruf geprüft. Mit temporären Testschlüsseln: RSA 2048 und Ed25519 akzeptiert; RSA 1024, private Schlüssel, ungültige Schlüsseldaten und Eingabe mit authorized_keys-Optionen verworfen. CRLF, Kommentare und Duplikate geprüft. Effektive SSH-Regeln mit isolierter OpenSSH-Konfiguration unter IPv4/IPv6 und widersprechender Match-Regel geprüft; ungültige Argumente und Benutzernamen geprüft. Tests liefen unter Ubuntu 24.04 mit OpenSSH, keine vollständige Installation auf Debian 12/13 und keine Installation auf einem produktiven Server. ShellCheck war nicht installiert.
