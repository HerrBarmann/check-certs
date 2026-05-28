# check-certs

[🇬🇧 Read in English](README.md)

Kennst du das Gefühl, wenn ein Nutzer anruft und meldet, dass der Browser eine Sicherheitswarnung für deine Website anzeigt? Oder wenn die LDAP-Authentifizierung um 3 Uhr morgens stillschweigend aufhört zu funktionieren, weil ein Zertifikat abgelaufen ist – während du geschlafen hast?

check-certs überwacht die Ablaufdaten deiner SSL-Zertifikate und schlägt rechtzeitig Alarm, bevor etwas schiefgeht. Alle Server werden parallel geprüft, die vollständige Zertifikatskette verifiziert (nicht nur das Endzertifikat – eine defekte Zwischenstelle wird erkannt und gemeldet), STARTTLS-Protokolle wie SMTP, IMAP und LDAP automatisch erkannt, und zwischen den Läufen wird der Zustand gespeichert – du bekommst also nur eine Meldung, wenn sich wirklich etwas geändert hat. Benachrichtigungen landen dort, wo du sie haben willst: als farbcodierte Terminal-Tabelle für den schnellen Überblick, als native macOS-Benachrichtigung, per E-Mail, HTTP-Webhook, Microsoft Teams, ntfy oder Pushover mit Notfallpriorität und Quittierungspflicht.

Keine unerwarteten Ablaufdaten mehr. Keine peinlichen Anrufe mehr. Einfach Zertifikate, die still ihre Fristen einhalten.

---

## Inhalt

- [Übersicht](#übersicht)
- [Installation](#installation)
  - [macOS](#macos)
  - [Linux](#linux)
- [Serverkonfiguration](#serverkonfiguration)
- [Konfiguration](#konfiguration)
- [Verwendung](#verwendung)
- [Einzelserver-Prüfung](#einzelserver-prüfung)
- [Ausgabe](#ausgabe)
- [Hintergrundüberwachung](#hintergrundüberwachung)
- [Dateien](#dateien)
- [Fehlerbehebung](#fehlerbehebung)
- [Mitwirken](#mitwirken)
- [Lizenz](#lizenz)

---

## Übersicht

check-certs besteht aus `check-certs.sh` und den darauf aufbauenden Automatisierungsvarianten.

**`check-certs.sh`** ist das Hauptskript – eine farbig kodierte Terminal-Tabelle, die auf macOS und Linux läuft. Es enthält außerdem die gemeinsame Kernlogik, auf der alle Automatisierungsvarianten aufbauen. Der Installer schließt es immer ein.

Sechs optionale Automatisierungsvarianten ergänzen es um Hintergrundüberwachung:

| Variante | Skript | Plattform | Details |
| -------- | ------ | --------- | ------- |
| **Benachrichtigung** | `check-certs-notify.sh` | macOS | Native Benachrichtigungen via launchd → [docs/macos-notify.md](docs/macos-notify.md) |
| **E-Mail** | `check-certs-mail.sh` | Linux + macOS | E-Mail via Postfix, ssmtp oder sendmail → [docs/email.md](docs/email.md) |
| **Webhook** | `check-certs-webhook.sh` | Linux + macOS | HTTP POST an Slack, ntfy, Teams, eigene Endpunkte → [docs/webhook.md](docs/webhook.md) |
| **Teams** | `check-certs-teams.sh` | Linux + macOS | Adaptive Card an Microsoft Teams via Workflow-Webhook → [docs/teams.md](docs/teams.md) |
| **Pushover** | `check-certs-pushover.sh` | Linux + macOS | Mobile Push mit Prioritätsstufen und Notfallbestätigung → [docs/pushover.md](docs/pushover.md) |
| **ntfy** | `check-certs-ntfy.sh` | Linux + macOS | Push-Benachrichtigungen via ntfy.sh oder eigenem ntfy-Server → [docs/ntfy.md](docs/ntfy.md) |

**Wichtigste Merkmale:**

- Prüft alle Server **parallel** (bis zu `MAX_JOBS` gleichzeitige Verbindungen, Ergebnisse in der Reihenfolge der `servers.conf`)
- Verifiziert die **vollständige Zertifikatskette**, nicht nur das Endzertifikat – eine defekte Zwischenstelle wird erkannt und gemeldet
- **Statusverfolgung** zwischen den Läufen: du wirst nur benachrichtigt, wenn sich etwas ändert – nicht bei jedem Durchlauf
- **Eskalationsstufen** mit eigenem Verhalten für Warnung, kritisch und dringend
- **STARTTLS** wird auf Standardports automatisch erkannt (SMTP, IMAP, POP3, LDAP, FTP, XMPP)

---

## Installation

### macOS

**Voraussetzung:** Homebrew (`coreutils` und `openssl` werden automatisch installiert).

**Automatisch** – installiert `check-certs.sh`, richtet den Befehl als Symlink in `/usr/local/bin/` ein und konfiguriert optional eine oder mehrere Automatisierungsvarianten (Benachrichtigungen, E-Mail, Webhook, Teams, Pushover, ntfy) via launchd:

```bash
chmod +x install/install.sh && sudo ./install/install.sh
```

**Manuell** – nur Terminal-Tabelle:

```bash
brew install coreutils openssl
sudo mkdir -p /usr/local/lib/check-certs
sudo cp src/check-certs.sh /usr/local/lib/check-certs/
sudo chmod +x /usr/local/lib/check-certs/check-certs.sh
sudo ln -s /usr/local/lib/check-certs/check-certs.sh /usr/local/bin/check-certs
mkdir -p ~/.config/check-certs
cp config/servers.conf config/check-certs.conf ~/.config/check-certs/
```

Für Hintergrundüberwachung nach einer manuellen Installation das entsprechende Skript aus `src/` nach `/usr/local/lib/check-certs/` kopieren und der Anleitung folgen:

- 🍎 [macOS-Benachrichtigungen](docs/macos-notify.md) – `check-certs-notify.sh`
- 📧 [E-Mail](docs/email.md) – `check-certs-mail.sh`
- 🌐 [Webhook](docs/webhook.md) – `check-certs-webhook.sh`
- 💬 [Teams](docs/teams.md) – `check-certs-teams.sh`
- 📱 [Pushover](docs/pushover.md) – `check-certs-pushover.sh`
- 🔔 [ntfy](docs/ntfy.md) – `check-certs-ntfy.sh`

### Linux

GNU `date` ist nativ verfügbar – kein Homebrew oder `coreutils` nötig.

**Automatisch** (Debian/Ubuntu) – installiert `check-certs.sh`, richtet den Befehl als Symlink in `/usr/local/bin/` ein und konfiguriert optional eine oder mehrere Automatisierungsvarianten (E-Mail, Webhook, Teams, Pushover, ntfy) via cron:

```bash
chmod +x install/install.sh && sudo ./install/install.sh
```

**Manuell** – nur Terminal-Tabelle:

```bash
apt install openssl        # Debian/Ubuntu
# oder: dnf install openssl  # Fedora/RHEL

sudo mkdir -p /opt/check-certs
sudo cp src/check-certs.sh config/servers.conf config/check-certs.conf /opt/check-certs/
sudo chmod +x /opt/check-certs/check-certs.sh
sudo ln -s /opt/check-certs/check-certs.sh /usr/local/bin/check-certs
```

Für Hintergrundüberwachung nach einer manuellen Installation das entsprechende Skript aus `src/` ins Installationsverzeichnis kopieren und der Anleitung folgen:

- 📧 [E-Mail](docs/email.md) – `check-certs-mail.sh`
- 🌐 [Webhook](docs/webhook.md) – `check-certs-webhook.sh`
- 💬 [Teams](docs/teams.md) – `check-certs-teams.sh`
- 📱 [Pushover](docs/pushover.md) – `check-certs-pushover.sh`
- 🔔 [ntfy](docs/ntfy.md) – `check-certs-ntfy.sh`

---

## Serverkonfiguration

`servers.conf` wird von allen Varianten gemeinsam verwendet. Server werden in benannten **Gruppen** organisiert:

```
# Zeilen, die mit # beginnen, sind Kommentare

[LDAP]
ldap.example.com:636:ldaps
ldap-plain.example.com:389
ldap-ng.example.com:389:ldap

[Mail]
mail.example.com:587:submission
imap.example.com:143:imap
imap.example.com:993:imaps

[Web]
www.example.com:443:https
intranet.example.com:443:https

[Services]
ticketing.example.com:443:https
custom.example.com:8443:tls
```

**Eintragsformat:** `hostname:port` oder `hostname:port:proto`

IPv6-Adressen verwenden Klammernotation: `[2001:db8::1]:443` oder `[::1]:636:ldaps`

STARTTLS wird auf Standardports automatisch erkannt. Mit optionalen `key=value`-Paaren nach dem Port lassen sich die globalen Schwellenwerte für einzelne Server überschreiben:

| Option | Beschreibung |
| ------ | ------------ |
| `warn=N` | Warnschwelle in Tagen |
| `crit=N` | Kritisch-Schwelle in Tagen |
| `urgent=N` | Dringend-Schwelle in Tagen (0 = deaktiviert) |
| `timeout=N` | Verbindungs-Timeout in Sekunden |

```
api.example.com:443 warn=30 crit=14   # strengere Schwellen für eine kritische API
internal.example.com:443 warn=7        # entspannter für interne Tools
slow.example.com:443 timeout=15        # längeres Timeout für langsame Hosts
```

`check-certs --list` zeigt aktive Einstellungen neben jedem Eintrag. Das optionale `:proto`-Feld überschreibt die automatische Protokollerkennung oder erzwingt reines TLS auf einem nicht-standardmäßigen Port.

| Port(s) | Automatisch erkanntes Protokoll |
| ------- | ------------------------------- |
| 25, 587 | `smtp` |
| 143 | `imap` |
| 110 | `pop3` |
| 389 | `ldap` |
| 21 | `ftp` |
| 5222 | `xmpp` |
| alle anderen | reines TLS |

STARTTLS-Protokolle: `smtp` `submission` `imap` `pop3` `ldap` `ftp` `xmpp`

Reines-TLS-Aliase (selbsterklärend, kein STARTTLS): `tls` `https` `ldaps` `imaps` `pop3s` `smtps` `ftps`

> Eine vorhandene `servers.conf` wird bei einer Neuinstallation **niemals überschrieben**.

---

## Konfiguration

Alle Einstellungen stehen in `check-certs.conf`. Der Installer schreibt eine minimale `check-certs.conf` mit nur den Einstellungen, die für die gewählte Variante relevant sind. Bei manueller Installation `config/check-certs.conf` aus dem Repository als Ausgangspunkt kopieren – die Datei dokumentiert alle verfügbaren Einstellungen. Änderungen werden direkt in der Datei vorgenommen – die Skripte selbst müssen nie angepasst werden.

```bash
nano ~/.config/check-certs/check-certs.conf   # macOS
nano /opt/check-certs/check-certs.conf         # Linux
```

Wichtige Einstellungen:

| Einstellung | Standard | Beschreibung |
| ----------- | -------- | ------------ |
| `WARN_DAYS` | `15` | Erste Warnung X Tage vor Ablauf |
| `CRIT_DAYS` | `7` | Tägliche Erinnerung ab X Tagen vor Ablauf |
| `URGENT_DAYS` | `2` | Notfallmeldung ab X Tagen (0 = deaktiviert) |
| `TIMEOUT` | `5` | Verbindungs-Timeout pro Server in Sekunden |
| `MAX_JOBS` | `10` | Maximale Anzahl paralleler Prüfungen |
| `MAIL_TRANSPORT` | `postfix` (Linux) / `ssmtp` (macOS) | E-Mail-Transport: `postfix`, `ssmtp` oder `sendmail` |
| `MAIL_TO` | – | Primärer E-Mail-Empfänger |
| `MAIL_TO_URGENT` | – | Zweiter Empfänger für dringende Meldungen |
| `MAIL_FROM` | – | Absenderadresse |
| `WEBHOOK_URL` | – | URL für HTTP-POST-Benachrichtigungen |
| `TEAMS_WEBHOOK_URL` | – | Teams-Workflow-Webhook-URL |
| `PUSHOVER_APP_TOKEN` | – | Pushover-Anwendungstoken |
| `PUSHOVER_USER_KEY` | – | Pushover-Benutzer- oder Gruppenschlüssel |
| `NTFY_URL` | – | ntfy-Server-URL (z.B. `https://ntfy.sh`) |
| `NTFY_TOPIC` | – | ntfy-Topic-Name |
| `NTFY_TOKEN` | – | ntfy-Zugriffstoken (optional, für geschützte Topics) |

> Bei einer Neuinstallation sichert der Installer eine vorhandene `check-certs.conf` als `check-certs.conf.bak`, bevor er sie überschreibt.

---

## Verwendung

```bash
check-certs                                 # Alle Server aus servers.conf prüfen
check-certs <hostname>                      # Einzelnen Server prüfen (Port-Standard: 443)
check-certs <hostname>:<port>               # Einzelnen Server auf einem bestimmten Port prüfen
check-certs <hostname>:<port>:<proto>       # Mit explizitem STARTTLS-Protokoll prüfen
check-certs --scan <hostname>               # Häufige TLS-Ports scannen (Onboarding-Hilfe)
check-certs --list                          # Alle Server auflisten ohne zu prüfen
check-certs --check                          # key=value für alle Server aus servers.conf
check-certs --check <host>[:<port>]          # key=value für einen einzelnen Host (Port-Standard: 443)
check-certs --check <host1> <host2> …        # key=value Batch-Modus (mehrere Hosts parallel)
check-certs --check --nagios <host>[:<port>] … # Nagios/Icinga-Ausgabe, eine Zeile pro Host
check-certs --check --json                   # JSON-Array für alle Server
check-certs --check --json <host>[:<port>]    # JSON-Objekt für einen einzelnen Host
check-certs --check --json <host1> <host2> … # JSON-Array für mehrere Hosts
check-certs --clear-state                   # Statusdateien zurücksetzen (erzwingt neue Benachrichtigungen)
check-certs --version                       # Version anzeigen
check-certs --help                          # Hilfe anzeigen
```

---

## Einzelserver-Prüfung

`check-certs --check` gibt maschinenlesbare Ausgabe zurück – nützlich für Skripte, Monitoring-Integrationen und das Testen von STARTTLS-Konfigurationen. Ohne Argumente werden alle Server aus `servers.conf` geprüft. Mit einem einzelnen Host wird nur dieser geprüft (Port-Standard: 443). Mehrere Hosts werden parallel geprüft (Batch-Modus). IPv6-Adressen verwenden Klammernotation: `[::1]:443`.

**Ausgabemodi:**

```bash
check-certs --check                                       # kv für alle Server aus servers.conf
check-certs --check --json                                # JSON-Array für alle Server
check-certs --check mail.example.com                      # kv, einzelner Host, Port-Standard: 443
check-certs --check mail.example.com:587                  # kv, expliziter Port
check-certs --check api.example.com ldap.example.com:636  # Batch-Modus, zwei Hosts parallel
check-certs --check --nagios mail.example.com:587         # Nagios/Icinga-Ausgabe
check-certs --check --json mail.example.com:587           # JSON-Objekt
check-certs --check --json api.example.com ldap.example.com:636  # JSON-Array
```

**key=value-Ausgabe** – ein Feld pro Zeile, nach Schlüsselname parsen, nicht nach Position:

```
host=mail.example.com
port=587
proto=smtp
days=12
expiry=Jun 01 2026
expiry_ts=1748736000
ca=Let's Encrypt
status=WARNING
chain=OK
```

| Feld | Beschreibung |
| ---- | ------------ |
| `host` | Hostname wie angegeben |
| `port` | Geprüfter Port |
| `proto` | Verwendetes STARTTLS-Protokoll (`smtp`, `ldap`, …) oder `tls` für reines TLS |
| `status` | `OK`, `WARNING`, `CRITICAL`, `URGENT`, `EXPIRED` oder `ERROR` |
| `days` | Tage bis zum Ablauf (negativ, wenn bereits abgelaufen) |
| `expiry` | Ablaufdatum, lesbar (`Mon DD YYYY`) |
| `expiry_ts` | Ablaufdatum als Unix-Timestamp |
| `ca` | Name des Zertifikatsausstellers |
| `chain` | `OK` oder eine Fehlermeldung zur Kettenverifizierung |

Bei `ERROR` (nicht erreichbar oder ungültiger Port) werden nur `host`, `port`, `proto`, `status` und `reason` ausgegeben.

**Exit-Codes:**

| Code | Bedeutung |
| ---- | --------- |
| `0` | OK (Zertifikat gültig, Kette OK) |
| `1` | WARNING |
| `2` | CRITICAL, URGENT, EXPIRED oder ERROR |
| `3` | UNKNOWN – Host nicht erreichbar (nur `--nagios`-Modus) |

**Skript-Beispiele:**

```bash
# Nach Exit-Code verzweigen
if ! check-certs --check api.example.com; then
    echo "Zertifikatsproblem auf api.example.com"
fi

# Einzelnes Feld auslesen
days=$(check-certs --check cert.example.com | grep "^days=" | cut -d= -f2)
[ "$days" -lt 14 ] && send_alert "Zertifikat läuft in ${days}d ab"

# Ablauf-Timestamps mehrerer Hosts vergleichen
check-certs --check a.example.com | grep "^expiry_ts="
check-certs --check b.example.com | grep "^expiry_ts="

# Als Nagios/Icinga-Plugin verwenden
check-certs --check --nagios monitor.example.com:443

# Ausgabe in Dashboard oder Log-Pipeline einspeisen
check-certs --check --json api.example.com:443
```

---

## Ausgabe

Farbcodierte Tabelle im Terminal, gruppiert nach den Abschnitten aus `servers.conf`:

```
╔══════════════════════════════════╦════════════════════╦════════════════╦════════════════════════╦═════╗
║ Server                           ║ Ablaufdatum        ║ Verbleibend    ║ Ausgestellt von        ║ Ch  ║
╠══════════════════════════════════╬════════════════════╬════════════════╬════════════════════════╬═════╣
╠  LDAP ══════════════════════════════════════════════════════════════════════════════════════════════╣
║ ldap.example.com                 ║ Nov 20 2026        ║ ✓ 185d         ║ R11                    ║ ✓   ║
║ ldap-dev.example.com             ║ -                  ║ ERROR          ║ Unreachable            ║     ║
╠══════════════════════════════════╬════════════════════╬════════════════╬════════════════════════╬═════╣
╠  Web ═══════════════════════════════════════════════════════════════════════════════════════════════╣
║ www.example.com                  ║ Jul 14 2026        ║ ⚠ 28d          ║ GEANT TLS RSA 1        ║ ✓   ║
║ intranet.example.com             ║ Jun 01 2026        ║ ✗ 14d          ║ GEANT TLS RSA 1        ║ ⚠   ║
╚══════════════════════════════════╩════════════════════╩════════════════╩════════════════════════╩═════╝

  Zusammenfassung:  4 Server geprüft  │  ✓ 1 OK  │  ⚠ 1 Warnung  │  ✗ 2 Kritisch/Fehler
```

| Farbe | Bedingung | Bedeutung |
| ----- | --------- | --------- |
| 🟢 Grün | ≥ `WARN_DAYS` verbleibend | Alles in Ordnung |
| 🟡 Gelb | < `WARN_DAYS` verbleibend | Bald erneuern |
| 🔴 Rot | < `CRIT_DAYS` verbleibend | Handlungsbedarf |
| 🔴 Rot / ERROR | – | Server nicht erreichbar |

Die Spalte **„Ausgestellt von"** zeigt den CN-Wert aus dem Zertifikatsaussteller (z.B. `R11` für Let's Encrypt, `GEANT TLS RSA 1` für GÉANT); fehlt ein CN, wird der O-Wert verwendet. Die Spalte **Ch** zeigt `✓` wenn die vollständige Zertifikatskette gültig ist, oder `⚠` wenn ein Zwischenzertifikat fehlt oder ungültig ist. Eine defekte Kette stuft ein sonst gültiges Zertifikat auf CRITICAL hoch – das Feld `chain_status` in der `--check`-Ausgabe enthält den genauen Fehlertext.

---

## Hintergrundüberwachung

Sobald `check-certs.sh` läuft, lässt sich die automatische Hintergrundüberwachung einfach dazuschalten. Alle Varianten verwenden dieselbe `servers.conf` und `check-certs.conf`, benachrichtigen nur bei Zustandsänderungen und eskalieren stufenweise von Warnung über kritisch bis dringend mit täglichen Erinnerungen für ungelöste Probleme.

- 🍎 **[macOS-Benachrichtigungen](docs/macos-notify.md)** – täglicher launchd-Job mit nativen macOS-Benachrichtigungen und Eskalationsstufen
- 📧 **[E-Mail](docs/email.md)** – tägliche E-Mail-Berichte via Postfix, ssmtp oder sendmail (Linux und macOS)
- 🌐 **[Webhook](docs/webhook.md)** – HTTP POST an Slack, ntfy.sh, Teams, Mattermost oder beliebige Endpunkte
- 💬 **[Teams](docs/teams.md)** – vollständige Adaptive Card an einen Microsoft Teams-Kanal via Workflow-Webhook
- 📱 **[Pushover](docs/pushover.md)** – mobile Push-Benachrichtigungen mit Notfallbestätigung für iOS und Android
- 🔔 **[ntfy](docs/ntfy.md)** – Push-Benachrichtigungen via ntfy.sh oder eigenem ntfy-Server
- 🔧 **[Eigene Wrapper erstellen](docs/wrapper-interface.md)** – vollständige Schnittstellenreferenz für eigene Benachrichtigungsskripte

---

## Dateien

```
README.md
README-DE.md
CHANGELOG.md
CONTRIBUTING.md
LICENSE

docs/
├── macos-notify.md          ← macOS-Benachrichtigungsvariante
├── email.md                 ← E-Mail-Variante (Postfix, ssmtp oder sendmail)
├── webhook.md               ← Webhook-Variante
├── teams.md                 ← Microsoft Teams Adaptive Card-Variante
├── pushover.md              ← Pushover-Variante
├── ntfy.md                  ← ntfy-Variante
├── wrapper-interface.md     ← Schnittstellenreferenz für eigene Wrapper
└── troubleshooting.md       ← Fehlerbehebung für alle Plattformen

src/
├── check-certs.sh               ← Hauptskript – Terminal-Tabelle + Kernlogik
├── check-certs-notify.sh        ← macOS-Benachrichtigungsvariante
├── check-certs-mail.sh          ← E-Mail-Variante
├── check-certs-webhook.sh       ← Webhook-Variante
├── check-certs-teams.sh         ← Teams-Variante
├── check-certs-pushover.sh      ← Pushover-Variante
└── check-certs-ntfy.sh          ← ntfy-Variante

install/
├── install.sh                     ← Installer für macOS und Linux
├── cleanup-macos.sh               ← Bereinigungsskript für Pre-2.7.0-Installationen
├── com.check-certs.notify.plist   ← launchd-Jobvorlage (Benachrichtigungen)
├── com.check-certs.mail.plist     ← launchd-Jobvorlage (E-Mail)
├── com.check-certs.webhook.plist  ← launchd-Jobvorlage (Webhook)
├── com.check-certs.teams.plist    ← launchd-Jobvorlage (Teams)
├── com.check-certs.pushover.plist ← launchd-Jobvorlage (Pushover)
├── com.check-certs.ntfy.plist     ← launchd-Jobvorlage (ntfy)
└── check-certs.logrotate          ← logrotate-Konfiguration (Linux)

config/
├── servers.conf                 ← Beispiel-Serverliste
└── check-certs.conf             ← Konfigurationsdatei (alle Einstellungen dokumentiert)

tests/
└── test_check_certs.sh          ← Unit-Test-Suite (kein Netzwerkzugriff nötig)
```

---

## Fehlerbehebung

| Fehler | Lösung |
| ------ | ------ |
| `check-certs.sh not found` | Das Skript liegt nicht im selben Verzeichnis wie der aufrufende Wrapper |
| *"Server file not found"* | `SERVER_FILE` in `check-certs.conf` prüfen oder sicherstellen, dass `servers.conf` vorhanden ist |
| *"Unreachable"* | `openssl s_client -connect hostname:port </dev/null` |
| *"Invalid format"* | Trennzeichen in `servers.conf` muss `:` sein, nicht `,` |
| CA zeigt „Unknown" | `openssl s_client -connect hostname:port </dev/null 2>/dev/null \| openssl x509 -noout -issuer` |
| Kette wird immer als ungültig angezeigt | Meist fehlt ein Zwischenzertifikat im lokalen Vertrauensspeicher. CA-Zertifikate aktualisieren: `brew install ca-certificates` (macOS) oder `apt install ca-certificates` (Linux). Prüfen mit: `openssl s_client -connect hostname:port -servername hostname </dev/null` |
| *"gdate: command not found"* | Nur macOS: `brew install coreutils` |
| *"Homebrew not found"* | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| `check-certs` Befehl nicht gefunden | macOS: Symlink prüfen: `ls -la /usr/local/bin/check-certs`. Linux: `source ~/.bashrc` ausführen oder neues Terminal öffnen. |

Für weiterführende Hilfe und variantenspezifische Probleme siehe [docs/troubleshooting.md](docs/troubleshooting.md).

---

## Mitwirken

Beiträge sind willkommen. Für größere Features bitte zuerst ein Issue öffnen, damit wir den Ansatz besprechen können. Für Bugfixes reicht ein Pull Request mit einer kurzen Beschreibung des Problems und der Lösung.

## Lizenz

MIT – siehe [LICENSE](LICENSE) für den vollständigen Text.
