# check-certs

[🇬🇧 Read in English](README.md)

Kennst du das Gefühl, wenn ein Nutzer anruft und meldet, dass der Browser eine Sicherheitswarnung für deine Website anzeigt? Oder wenn die LDAP-Authentifizierung um 3 Uhr morgens stillschweigend aufhört zu funktionieren, weil ein Zertifikat abgelaufen ist – während du geschlafen hast?

check-certs überwacht die Ablaufdaten deiner SSL-Zertifikate und schlägt rechtzeitig Alarm, bevor etwas schiefgeht. Prüfungen laufen parallel, die vollständige Zertifikatskette wird verifiziert (nicht nur das Endzertifikat), STARTTLS-Protokolle wie SMTP, IMAP und LDAP werden automatisch erkannt, und zwischen den Läufen wird der Zustand gespeichert – du bekommst also nur eine Meldung, wenn sich wirklich etwas geändert hat. Benachrichtigungen landen dort, wo du sie haben willst: als farbcodierte Terminal-Tabelle für den schnellen Überblick, als native macOS-Benachrichtigung, per E-Mail, HTTP-Webhook, Microsoft Teams oder Pushover mit Notfallpriorität und Quittierungspflicht.

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
- [Funktionsweise](#funktionsweise)
- [Hintergrundüberwachung](#hintergrundüberwachung)
- [Dateien](#dateien)
- [Fehlerbehebung](#fehlerbehebung)
- [Mitwirken](#mitwirken)
- [Lizenz](#lizenz)

---

## Übersicht

check-certs besteht aus `check-certs.sh` und den darauf aufbauenden Automatisierungsvarianten.

**`check-certs.sh`** ist das Hauptskript – eine farbig kodierte Terminal-Tabelle, die auf macOS und Linux läuft. Es enthält außerdem die gemeinsame Kernlogik, auf der alle Automatisierungsvarianten aufbauen. Beide Installer schließen es immer ein.

Fünf optionale Automatisierungsvarianten ergänzen es um Hintergrundüberwachung:

| Variante | Skript | Plattform | Details |
| -------- | ------ | --------- | ------- |
| **Benachrichtigung** | `check-certs-notify.sh` | macOS | Native Benachrichtigungen via launchd → [docs/macos-notify.md](docs/macos-notify.md) |
| **E-Mail** | `check-certs-mail.sh` | Linux + macOS | E-Mail via Postfix, ssmtp oder sendmail, gesteuert durch `MAIL_TRANSPORT` → [docs/email.md](docs/email.md) |
| **Webhook** | `check-certs-webhook.sh` | Linux + macOS | HTTP POST an Slack, ntfy, Teams, eigene Endpunkte → [docs/webhook.md](docs/webhook.md) |
| **Teams** | `check-certs-teams.sh` | Linux + macOS | Adaptive Card an Microsoft Teams via Workflow-Webhook → [docs/teams.md](docs/teams.md) |
| **Pushover** | `check-certs-pushover.sh` | Linux + macOS | Mobile Push mit Prioritätsstufen und Notfallbestätigung → [docs/pushover.md](docs/pushover.md) |

**Wichtigste Merkmale:**

- Prüft alle Server **parallel** – die Ergebnisse erscheinen in der Reihenfolge der `servers.conf`
- Verifiziert die **vollständige Zertifikatskette**, nicht nur das Endzertifikat – eine defekte Zwischenstelle wird erkannt und gemeldet
- **Statusverfolgung** zwischen den Läufen: du wirst nur benachrichtigt, wenn sich etwas ändert – nicht bei jedem Durchlauf
- **Eskalationsstufen** mit eigenem Verhalten für Warnung, kritisch und dringend

---

## Installation

### macOS

**Voraussetzung:** Homebrew (`coreutils` und `openssl` werden automatisch installiert).

**Automatisch** – installiert `check-certs.sh`, richtet den Alias ein und konfiguriert optional eine oder mehrere Automatisierungsvarianten (Benachrichtigungen, E-Mail, Webhook, Teams, Pushover) via launchd:

```bash
chmod +x install/install.sh && ./install/install.sh
```

**Manuell** – nur Terminal-Tabelle:

```bash
brew install coreutils openssl
mkdir -p ~/scripts/check-certs
cp src/check-certs.sh config/servers.conf config/check-certs.conf ~/scripts/check-certs/
chmod +x ~/scripts/check-certs/check-certs.sh
echo 'alias check-certs="$HOME/scripts/check-certs/check-certs.sh"' >> ~/.zshrc
source ~/.zshrc
```

Für Hintergrundüberwachung nach einer manuellen Installation siehe [docs/macos-notify.md](docs/macos-notify.md), [docs/email.md](docs/email.md), [docs/webhook.md](docs/webhook.md), [docs/teams.md](docs/teams.md) oder [docs/pushover.md](docs/pushover.md).

### Linux

GNU `date` ist nativ verfügbar – kein Homebrew oder `coreutils` nötig.

**Automatisch** (Debian/Ubuntu) – installiert `check-certs.sh` und konfiguriert optional eine oder mehrere Automatisierungsvarianten (E-Mail, Webhook, Teams, Pushover) via cron:

```bash
chmod +x install/install.sh && sudo ./install/install.sh
```

**Manuell** – nur Terminal-Tabelle:

```bash
apt install openssl        # Debian/Ubuntu
# oder: dnf install openssl  # Fedora/RHEL

mkdir -p ~/scripts/check-certs
cp src/check-certs.sh config/servers.conf config/check-certs.conf ~/scripts/check-certs/
chmod +x ~/scripts/check-certs/check-certs.sh
echo 'alias check-certs="$HOME/scripts/check-certs/check-certs.sh"' >> ~/.bashrc
source ~/.bashrc
```

Für Hintergrundüberwachung nach einer manuellen Installation siehe [docs/email.md](docs/email.md), [docs/webhook.md](docs/webhook.md), [docs/teams.md](docs/teams.md) oder [docs/pushover.md](docs/pushover.md).

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

**Eintragsformat:** `hostname:port[:proto] [key=value ...]`

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

Alle Einstellungen stehen in `check-certs.conf` im selben Verzeichnis wie die Skripte. Der Installer schreibt eine minimale `check-certs.conf` mit nur den Einstellungen, die für die gewählte Variante relevant sind. Bei manueller Installation kopiere `config/check-certs.conf` aus dem Repository als Ausgangspunkt – die Datei dokumentiert alle verfügbaren Einstellungen. Änderungen werden direkt in der Datei vorgenommen – die Skripte selbst müssen nie angepasst werden.

```bash
nano ~/scripts/check-certs/check-certs.conf   # macOS
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
| `MAIL_TO` | – | Primärer E-Mail-Empfänger (E-Mail-Variante) |
| `MAIL_TO_URGENT` | – | Zweiter Empfänger für dringende Meldungen (E-Mail-Variante) |
| `MAIL_FROM` | – | Absenderadresse (E-Mail-Variante) |
| `WEBHOOK_URL` | – | URL für HTTP-POST-Benachrichtigungen (Webhook-Variante) |
| `TEAMS_WEBHOOK_URL` | – | Teams-Workflow-Webhook-URL (Teams-Variante) |
| `PUSHOVER_APP_TOKEN` | – | Pushover-Anwendungstoken (Pushover-Variante) |
| `PUSHOVER_USER_KEY` | – | Pushover-Benutzer- oder Gruppenschlüssel (Pushover-Variante) |

> Bei einer Neuinstallation sichert der Installer eine vorhandene `check-certs.conf` als `check-certs.conf.bak`, bevor er sie überschreibt.

---

## Verwendung

```bash
check-certs                           # Alle Server aus servers.conf prüfen
check-certs <hostname>                # Einzelnen Server prüfen (Port-Standard: 443)
check-certs <hostname>:<port>         # Einzelnen Server auf einem bestimmten Port prüfen
check-certs <hostname>:<port>:<proto> # Mit explizitem STARTTLS-Protokoll prüfen
check-certs <hostname> <port>         # Wie oben, Port als zweites Argument
check-certs --list                    # Alle Server auflisten ohne zu prüfen
check-certs --check <host>:<port>     # Strukturierte Ausgabe für einen Server (skriptierbar)
check-certs --clear-state             # Statusdateien zurücksetzen (erzwingt neue Benachrichtigungen)
check-certs --version                 # Version anzeigen
check-certs --help                    # Hilfe anzeigen
```

---

## Ausgabe

Farbcodierte Tabelle im Terminal, gruppiert nach den Abschnitten aus `servers.conf`:

```
╔══════════════════════════════════╦════════════════════╦════════════════╦════════════════════════╗
║ Server                           ║ Ablaufdatum        ║ Verbleibend    ║ Ausgestellt von        ║
╠══════════════════════════════════╬════════════════════╬════════════════╬════════════════════════╣
╠  LDAP ══════════════════════════════════════════════════════════════════════════════════════════╣
║ ldap.example.com                 ║ Nov 20 2026        ║ ✓ 185d         ║ R11                    ║
║ ldap-dev.example.com             ║ -                  ║ ERROR          ║ Unreachable            ║
╠══════════════════════════════════╬════════════════════╬════════════════╬════════════════════════╣
╠  Web ═══════════════════════════════════════════════════════════════════════════════════════════╣
║ www.example.com                  ║ Jul 14 2026        ║ ⚠ 28d          ║ GEANT TLS RSA 1        ║
║ intranet.example.com             ║ Jun 01 2026        ║ ✗ 14d          ║ GEANT TLS RSA 1 ⚠chain ║
╚══════════════════════════════════╩════════════════════╩════════════════╩════════════════════════╝

  Zusammenfassung:  4 Server geprüft  │  ✓ 1 OK  │  ⚠ 1 Warnung  │  ✗ 2 Kritisch/Fehler
```

| Farbe | Bedingung | Bedeutung |
| ----- | --------- | --------- |
| 🟢 Grün | ≥ `WARN_DAYS` verbleibend | Alles in Ordnung |
| 🟡 Gelb | < `WARN_DAYS` verbleibend | Bald erneuern |
| 🔴 Rot | < `CRIT_DAYS` verbleibend | Handlungsbedarf |
| 🔴 Rot / ERROR | – | Server nicht erreichbar |

Die Spalte **„Ausgestellt von"** zeigt den CN-Wert aus dem Zertifikatsaussteller (z.B. `R11` für Let's Encrypt, `GEANT TLS RSA 1` für GÉANT); fehlt ein CN, wird der O-Wert verwendet. Das Suffix `⚠chain` weist auf eine defekte Zertifikatskette hin – auch wenn das Endzertifikat selbst noch gültig ist.

---

## Funktionsweise

Alle Server werden parallel geprüft (standardmäßig bis zu 10 gleichzeitige Verbindungen), die Ergebnisse erscheinen anschließend in der ursprünglichen `servers.conf`-Reihenfolge. Pro Host werden zwei `openssl`-Verbindungen aufgebaut: eine für Ablaufdatum und Aussteller des Endzertifikats, eine weitere zur Verifizierung der vollständigen Zertifikatskette mit `-verify_return_error`. Eine defekte Kette (z.B. eine abgelaufene oder fehlende Zwischenstelle) setzt den Status auf mindestens KRITISCH – unabhängig davon, wie viele Tage das Endzertifikat noch gültig ist.

Die maximale Parallelität (`MAX_JOBS` in `check-certs.conf`) verhindert Lastspitzen bei langen Serverlisten. Bei knappen Ressourcen reduzieren, bei vielen Servern und schneller Netzwerkanbindung erhöhen.

---

## Hintergrundüberwachung

Sobald `check-certs.sh` läuft, lässt sich die automatische Hintergrundüberwachung einfach dazuschalten:

- 🍎 **[macOS-Benachrichtigungen](docs/macos-notify.md)** – täglicher launchd-Job mit nativen macOS-Benachrichtigungen und Eskalationsstufen
- 📧 **[E-Mail](docs/email.md)** – tägliche E-Mail-Berichte via Postfix, ssmtp oder sendmail (Linux und macOS)
- 🌐 **[Webhook](docs/webhook.md)** – HTTP POST an Slack, ntfy.sh, Teams, Mattermost oder beliebige Endpunkte
- 💬 **[Teams](docs/teams.md)** – vollständige Adaptive Card an einen Microsoft Teams-Kanal via Workflow-Webhook
- 📱 **[Pushover](docs/pushover.md)** – mobile Push-Benachrichtigungen mit Notfallbestätigung für iOS und Android
- 🔧 **[Eigene Wrapper erstellen](docs/wrapper-interface.md)** – vollständige Schnittstellenreferenz für eigene Benachrichtigungsskripte

---

## Dateien

```
README.md
README-DE.md
LICENSE

docs/
├── macos-notify.md          ← macOS-Benachrichtigungsvariante
├── email.md                 ← E-Mail-Variante (Postfix, ssmtp oder sendmail, Linux + macOS)
├── webhook.md               ← Webhook-Variante
├── pushover.md              ← Pushover-Variante
├── teams.md                 ← Microsoft Teams Adaptive Card-Variante
├── wrapper-interface.md     ← Schnittstellenreferenz für eigene Wrapper
└── troubleshooting.md       ← Fehlerbehebung für alle Plattformen

src/
├── check-certs.sh               ← Hauptskript – Terminal-Tabelle + Kernlogik
├── check-certs-notify.sh        ← macOS-Benachrichtigungsvariante
├── check-certs-mail.sh          ← E-Mail-Variante (Postfix, ssmtp oder sendmail)
├── check-certs-webhook.sh       ← Webhook-Variante (HTTP POST, Linux + macOS)
├── check-certs-pushover.sh      ← Pushover-Variante (Mobile Push, Linux + macOS)
└── check-certs-teams.sh         ← Teams-Variante (Adaptive Card, Linux + macOS)

install/
├── install.sh                     ← Installer für macOS und Linux
├── com.check-certs.notify.plist   ← launchd-Jobvorlage (Benachrichtigungen)
├── com.check-certs.mail.plist     ← launchd-Jobvorlage (E-Mail)
├── com.check-certs.webhook.plist  ← launchd-Jobvorlage (Webhook)
├── com.check-certs.pushover.plist ← launchd-Jobvorlage (Pushover)
├── com.check-certs.teams.plist    ← launchd-Jobvorlage (Teams)
└── check-certs.logrotate          ← logrotate-Konfiguration (alle Varianten, Linux)

config/
├── servers.conf                 ← Beispiel-Serverliste
└── check-certs.conf             ← Konfigurationsdatei (alle Einstellungen)
```

---

## Fehlerbehebung

| Fehler | Lösung |
| ------ | ------ |
| `check-certs.sh not found` | Das Skript liegt nicht im selben Verzeichnis wie der aufrufende Wrapper |
| *"Server file not found"* | `SERVER_FILE` in `check-certs.conf` prüfen oder sicherstellen, dass `servers.conf` vorhanden ist |
| *"Unreachable"* | `openssl s_client -connect hostname:port </dev/null` |
| *"Invalid format"* | Trennzeichen in `servers.conf` muss `:` sein, nicht `,` |
| CA zeigt "Unknown" | `openssl s_client -connect hostname:port </dev/null 2>/dev/null \| openssl x509 -noout -issuer` |
| Kette wird immer als ungültig angezeigt | Meist fehlt ein Zwischenzertifikat im lokalen Vertrauensspeicher. CA-Zertifikate aktualisieren: `brew install ca-certificates` (macOS) oder `apt install ca-certificates` (Linux) |
| *"gdate: command not found"* | Nur macOS: `brew install coreutils` |
| *"Homebrew not found"* | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| `check-certs` Befehl nicht gefunden | `source ~/.zshrc` (macOS) oder `source ~/.bashrc` (Linux) ausführen |

Für weiterführende Hilfe und variantenspezifische Probleme siehe [docs/troubleshooting.md](docs/troubleshooting.md).

---

## Mitwirken

Beiträge sind willkommen. Für größere Features bitte zuerst ein Issue öffnen, damit wir den Ansatz besprechen können. Für Bugfixes reicht ein Pull Request mit einer kurzen Beschreibung des Problems und der Lösung.

## Lizenz

MIT – siehe [LICENSE](LICENSE) für den vollständigen Text.
