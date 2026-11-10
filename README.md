# autodarts-setup

Enkelt **one-liner**-skript för att förbereda en headless **Autodarts**-box på Raspberry Pi 4B (64-bit Raspberry Pi OS Lite) med **Tailscale**, OS-säkerhetsuppdateringar och veckovis uppdatering av Autodarts.

> **v0.1** — medvetet enkel. Testa alltid på riktig hårdvara innan kundleverans.

## Vad skriptet gör

| Steg | Beskrivning |
|------|-------------|
| Kontroller | Kräver root, `aarch64`, varnar om det inte ser ut som Raspberry Pi |
| Värdnamn | Sätter `autodarts-<CUSTOMER>` om `CUSTOMER` är satt |
| Tidszon | `Europe/Stockholm` (kan överskridas med `TZ`) |
| OS-uppdateringar | `unattended-upgrades` för säkerhetspatchar |
| Tailscale | Officiellt install-skript + `tailscale set --auto-update` |
| Autodarts | Officiell headless-install (`curl autodarts.sh/sh/install.sh`) som användaren `pi` (eller `BOARD_USER`) |
| Linger | `loginctl enable-linger` så användarens systemd-tjänster kan köra vid boot |
| Autodarts-uppdatering | Systemd-timer som kör `autodarts update` varje söndag ~03:30 |
| (Valfritt) | `INSTALL_UVC_HACK=1` installerar [UVC-hack](https://autodarts.diy/getting-started/installation/) för flera USB-kameror |

**Autodarts-tjänsten** (systemd user unit) skapas *inte* automatiskt — det gör du i Autodarts eget terminalgränssnitt under **Service**, enligt [officiell dokumentation](https://autodarts.diy/getting-started/installation/).

## Förkrav

1. Flasha **Raspberry Pi OS Lite (64-bit)** med [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
2. Aktivera **SSH** och sätt användare/lösenord (standard ofta `pi` om du skapar den).
3. Anslut **3 USB-kameror** och nätverk; boota Pi:n.
4. SSH:a in och kör one-linern.

## One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/WilliamLundqvist/autodarts-setup/main/install.sh | sudo bash
```

Med kundnamn och Tailscale auth key (rekommenderat i produktion):

```bash
export CUSTOMER="lundqvist"
export TS_AUTHKEY="tskey-auth-..."
curl -fsSL https://raw.githubusercontent.com/WilliamLundqvist/autodarts-setup/main/install.sh | sudo -E bash
```

Alternativ: klona repot och kör lokalt:

```bash
git clone https://github.com/WilliamLundqvist/autodarts-setup.git
cd autodarts-setup
sudo CUSTOMER=lundqvist TS_AUTHKEY='tskey-auth-...' ./install.sh
```

Skriptet är **idempotent** — säkert att köra om.

## Miljövariabler

| Variabel | Standard | Beskrivning |
|----------|----------|-------------|
| `CUSTOMER` | *(tom)* | Kund-ID → värdnamn `autodarts-<CUSTOMER>` och Tailscale-hostname |
| `TS_AUTHKEY` | *(tom)* | Tailscale auth key; utan den skriver `tailscale up` ut en login-URL |
| `BOARD_USER` | `pi` | Linux-användare som kör Autodarts (officiell install utan sudo) |
| `TZ` | `Europe/Stockholm` | Systemtidszon |
| `AUTODARTS_BETA` | `0` | Sätt till `1` för beta-spår (`--beta` till officiellt install) |
| `INSTALL_UVC_HACK` | `0` | Sätt till `1` för att köra Autodarts UVC-hack (3 kameror / USB-bandbredd) |

Inga hemligheter hårdkodas i repot.

## Efter installation — första gången

1. **Tailscale** — om du inte använde `TS_AUTHKEY`, följ länken som `tailscale up` visade (eller kör `sudo tailscale up` igen).
2. **Autodarts** — som board-användaren:

   ```bash
   sudo -u pi -H bash -lc 'autodarts'
   ```

   Logga in, koppla board, kalibrera kameror. Installera **Service** i menyn så daemonen startar vid boot.

3. **Kontrollera Tailscale** — från valfri enhet i tailnet: `tailscale status` eller admin-konsolen.

## Uppdateringar

| Komponent | Hur |
|-----------|-----|
| **Raspberry Pi OS** | `unattended-upgrades` (säkerhetsuppdateringar) |
| **Tailscale** | `tailscale set --auto-update` (satt av install-skriptet) |
| **Autodarts headless** | **Uppdateras inte automatiskt i bakgrunden** enligt [officiellt install-skript](https://autodarts.sh/sh/install.sh) — detta repo lägger till en **veckotimer** som kör `autodarts update`. Du kan även köra manuellt: `sudo -u pi -H autodarts update`. |
| **Autodarts Desktop** | Självuppdaterande via Velopack (inte relevant för headless) |

Källor:

- [Installation \| Autodarts Docs](https://autodarts.diy/getting-started/installation/) — headless, `autodarts update`, Service-menyn
- [autodarts.sh install.sh](https://autodarts.sh/sh/install.sh) — headless uppdateras via CLI, inte auto-updater som Desktop

## Nå brädan via Tailscale

När Pi:n är inloggad i ditt tailnet når du den på Tailscale-hostnamnet (t.ex. `autodarts-lundqvist`) eller dess Tailscale-IP. SSH:

```bash
ssh pi@autodarts-lundqvist
```

Autodarts webb/play sker via [play.autodarts.io](https://play.autodarts.io/) när boarden är kopplad till ditt konto — inte via en lokal webbport på Pi:n.

## Utveckling

Kör [ShellCheck](https://www.shellcheck.net/) på skriptet:

```bash
shellcheck install.sh
```

## Ej testat i denna miljö

Följande har **inte** körts på fysisk Raspberry Pi 4B i cloud-agent-miljön:

- Tailscale-inloggning och faktisk remote-åtkomst
- Autodarts headless-install, kamera-kalibrering och USB-bandbredd
- UVC-hack-kompilering på Pi
- systemd user service efter interaktiv setup i `autodarts`
- Veckotimer under verklig boot/linger

**William bör verifiera på en riktig enhet:** full one-liner, tre kameror, ev. `INSTALL_UVC_HACK=1`, Service-menyn, omstart, Tailscale-SSH, och att söndagstimern kör (eller testa manuellt: `sudo systemctl start autodarts-update.service`).
