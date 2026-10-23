# Protect Yourself

**One command that keeps your Linux server updated and locks it down against the automated attacks hitting every server on the internet.**

It's written for people who don't want to babysit a server. You paste one line, answer a couple of simple questions, and it:

- turns on **automatic security updates**,
- helps you set up an **SSH key** (a much safer login than a password),
- moves SSH to a **new, random port**, so bots that hammer port 22 never find it,
- turns on a **firewall** and **fail2ban** (which blocks anyone who keeps guessing logins),
- and gives you a **report** of everything it changed.

Nothing in the lockdown happens until you've seen a summary and said yes. At the end it lets you test the new login, and if that test fails, it puts SSH back the way it was.

> ⚠️ **Use at your own risk.** The script is careful, but every server is different. Try it on a test server first if you can, and keep your provider's web console handy (see [Locked out?](#locked-out)).

---

## Contents

- [Run it](#run-it)
- [What happens, step by step](#what-happens-step-by-step)
- [What each part does](#what-each-part-does)
- [Options](#options)
- [Connecting after it runs](#connecting-after-it-runs)
- [Running a website or other service?](#running-a-website-or-other-service)
- [Check that it's working](#check-that-its-working)
- [How to undo things](#how-to-undo-things)
- [FAQ and troubleshooting](#faq-and-troubleshooting)

---

## Run it

Log in to your server and paste this line:

```bash
curl -fsSL https://raw.githubusercontent.com/dieselbabyy/protect-yourself/main/protect-yourself.sh | sudo bash
```

**Supported systems:** Ubuntu, Debian, Rocky Linux, AlmaLinux, RHEL, Fedora, CentOS Stream, CentOS 7, Amazon Linux, openSUSE, SLES, Arch, Manjaro, EndeavourOS, and Alpine.

> 💡 Prefer to read it before you run it? Download it first, look it over, then run it:
> ```bash
> curl -fsSLO https://raw.githubusercontent.com/dieselbabyy/protect-yourself/main/protect-yourself.sh
> less protect-yourself.sh
> sudo bash protect-yourself.sh
> ```

---

## What happens, step by step

1. **Automatic updates get switched on.** This always happens, and you don't have to answer anything.
2. **SSH key check.** If your user already has an SSH key, it's used automatically. If not, you get a short menu:
   ```
   1) Import my key from GitHub
   2) Paste a public key I already have
   3) Make a new key for me             (recommended if you're not sure)
   4) Skip                              (keep password logins on)
   ```
3. **Summary screen.** You see exactly what the lockdown will change: firewall, fail2ban, your SSH key, the **new SSH port number**, and whether password logins get turned off.
4. **One question:** `Apply these changes? [y/N]`. If you answer no, nothing else is touched and your updates stay on.
5. **Lockdown.** The changes are applied in a safe order (details [below](#new-ssh-port)).
6. **Final report.** A box lists everything that changed, including your **new SSH port** and the exact command to connect. It's also saved to `/root/protect-yourself-report.txt`.
7. **Login test.** Open a **new** terminal window, try the command from the report, and type `y` if it worked. If you type `n`, or don't answer within 10 minutes, the SSH changes are undone automatically.

---

## What each part does

### Automatic updates

Each system uses its own official update tool, set up the recommended way:

| System | Tool | What gets installed | How often |
|---|---|---|---|
| Ubuntu, Debian | `unattended-upgrades` | security updates | daily |
| Rocky, Alma, RHEL, Oracle, Amazon Linux 2023 | `dnf-automatic` | security updates | daily |
| Fedora, CentOS Stream | `dnf-automatic` | all updates (these systems don't label security updates separately) | daily |
| CentOS 7, Amazon Linux 2 | `yum-cron` | security updates (all updates on CentOS) | daily |
| openSUSE, SLES | `zypper patch` | security patches | every 4 hours |
| Alpine | `apk upgrade` | all updates | every 4 hours |
| Arch, Manjaro, EndeavourOS | `checkupdates -d` | **downloads only** | every 4 hours |

**Why does Arch only download?** Arch's own documentation warns that upgrading without supervision can break the system, because some updates need a manual step. Updates get downloaded ahead of time, so running `sudo pacman -Syu` yourself is quick.

When a package comes with a new version of a config file you've edited, your version is kept, so updates never stop to ask a question.

### Reboots

Some updates, such as kernel fixes, only take effect after a reboot. The server reboots **at 4:00 AM server time, and only on nights when an update actually needs it**. To pick a different time, see [Options](#options).

| System | How the reboot is decided |
|---|---|
| Ubuntu, Debian | `unattended-upgrades` built-in reboot (`/var/run/reboot-required`) |
| Rocky, Alma, RHEL, Fedora | a nightly check with `dnf needs-restarting -r` |
| CentOS 7 | a nightly check with `needs-restarting -r` |
| openSUSE, SLES | a nightly check with `zypper needs-rebooting` |
| Arch, Alpine | no automatic reboots; reboot yourself after kernel updates |

### SSH keys

An SSH key is like a very long password that never leaves your computer and can't be guessed. Once a key works, password logins get turned off, which shuts down most break-in attempts.

The script checks the user you logged in as (the one who ran `sudo`). If that user has no key yet, you choose one of these:

| Option | Best for | What you do |
|---|---|---|
| **1. Import from GitHub** | People with a GitHub account that has an SSH key | Type your GitHub username. Your public keys are downloaded from `https://github.com/<username>.keys`. |
| **2. Paste a public key** | People who already have a key on their computer | Paste the line that starts with `ssh-ed25519` or `ssh-rsa` (usually in `~/.ssh/id_ed25519.pub`). **Never paste the private key.** |
| **3. Make a new key for me** | Everyone else | The server creates a key and shows the private half **once**, with instructions for saving it. After you press Enter, it's **deleted from the server**, so only you have it. |
| **4. Skip** | People who aren't ready yet | Password logins stay on. Everything else still gets protected. |

**Saving a key from option 3:**

*Mac or Linux.* In the Terminal app **on your own computer**, run:

```bash
mkdir -p ~/.ssh && nano ~/.ssh/protect-yourself_key
# paste the whole key, including the BEGIN and END lines, then press Ctrl+O, Enter, Ctrl+X
chmod 600 ~/.ssh/protect-yourself_key
```

*Windows 10 and 11.* Copy the key first, then run these in PowerShell **on your own computer**:

```powershell
mkdir -Force $HOME\.ssh
Set-Content -NoNewline -Encoding ascii $HOME\.ssh\protect-yourself_key ((Get-Clipboard -Raw).Replace("`r","").Trim() + "`n")
icacls $HOME\.ssh\protect-yourself_key /inheritance:r /grant:r "${env:USERNAME}:F"
```

*PuTTY.* Save the key as a text file, open **PuTTYgen**, choose **Conversions → Import key**, then **Save private key** to get a `.ppk` file.

Password logins are **only** turned off once a key is installed for your user. The script also fixes the permissions on the `~/.ssh` folder, because a wrong setting there makes SSH silently ignore keys.

### New SSH port

Bots scan port 22 all day long. Moving SSH to a random port between 20000 and 60000 that nothing else is using makes almost all of that noise disappear. (If your SSH is already on a non-standard port, it's left alone.)

The move is done in this order so you can't get locked out:

1. The new port is opened in the firewall and added to fail2ban **before** SSH restarts. The old port stays open for now.
2. On RHEL-family systems, SELinux is told that SSH may use the new port.
3. On Ubuntu 22.10 and newer, SSH is switched from "socket activation" to a normal service, so the new port actually takes effect.
4. The settings go into their own file, `/etc/ssh/sshd_config.d/00-protect-yourself.conf`. Older systems such as CentOS 7 get a clearly marked block at the top of `/etc/ssh/sshd_config` instead, and the original file is backed up first.
5. The new settings are checked with `sshd -t`, SSH restarts, and the script confirms SSH is **really listening** on the new port.
6. Only then is the old port closed. If anything fails along the way, everything is put back automatically and SSH stays on the old port.

Your current session stays connected the whole time.

> ☁️ **Cloud servers:** AWS, Google Cloud, Azure, and Oracle Cloud, plus any DigitalOcean, Hetzner, or Vultr cloud firewall you've set up, have their **own firewall outside the server**. You must open the new port there too, ideally **before** you answer yes. The script tries to detect AWS, Google, Azure, and Oracle and warns you.

### Firewall

The firewall blocks all incoming connections except:

- your SSH port,
- ports 80 and 443, **if** a website is already running on them,
- any ports you list in `OPEN_PORTS`.

Outgoing connections, such as updates and downloads, aren't affected.

| System | Firewall |
|---|---|
| Ubuntu, Debian, Arch | `ufw` |
| Rocky, Alma, RHEL, Fedora, CentOS, openSUSE, SLES | `firewalld` |
| Alpine | none (set one up with `awall` if you need it) |

If one of these firewalls is already running, it's used instead. Before you confirm, the summary lists any other programs listening for connections that the firewall will block.

### fail2ban

`fail2ban` watches login attempts. An address that fails **5 times within 10 minutes is banned for 1 hour**. Its settings live in `/etc/fail2ban/jail.d/protect-yourself.local`. On RHEL-family systems it comes from the EPEL repository, which the script enables for you.

### Final report

At the end you get a box like this, which is also saved to `/root/protect-yourself-report.txt`:

```
==============================================================================
  PROTECT-YOURSELF REPORT  -  myserver  -  2026-10-23 03:12:44 UTC
==============================================================================
  System:            Ubuntu 24.04 LTS
  Auto updates:      unattended-upgrades (security updates, daily)
  Reboots:           at 04:00, only when an update needs it
  Firewall:          ufw on: incoming blocked except TCP 41873
  fail2ban:          on: 5 failed logins = 1 hour ban
  SSH key:           installed for alice (generated, 1 new)
  Password login:    OFF (SSH keys only)
  SSH settings:      updated

  >>> YOUR NEW SSH PORT IS:  41873   (it used to be 22) <<<
  Connect with:  ssh -i ~/.ssh/protect-yourself_key -p 41873 alice@203.0.113.10

  !! KEEP THIS WINDOW OPEN. Test logging in from a NEW window first.
==============================================================================
```

To fill in the connect command, the script looks up your server's public IP with `api.ipify.org`. If that lookup fails, it uses the server's own address instead.

The full log is in `/var/log/protect-yourself.log`, and copies of every file it changed are in `/root/protect-yourself-backup-<date>/`.

---

## Options

All options are optional. Put them after `sudo` and before `bash`:

```bash
curl -fsSL https://raw.githubusercontent.com/dieselbabyy/protect-yourself/main/protect-yourself.sh | sudo REBOOT_TIME=05:30 SSH_PORT=40022 bash
```

| Option | Example | What it does |
|---|---|---|
| `REBOOT_TIME` | `REBOOT_TIME=05:30` | Time (24-hour clock, server time) to reboot **if** an update needs it. Default `04:00`. |
| `HARDEN` | `HARDEN=yes` / `HARDEN=no` | Answers the final question ahead of time. `no` = only automatic updates. |
| `SSH_PORT` | `SSH_PORT=40022` / `SSH_PORT=keep` | Pick your own SSH port (1024–65535), or `keep` to leave it where it is. |
| `GITHUB_USER` | `GITHUB_USER=octocat` | Import SSH keys from GitHub without being asked. |
| `SSH_PUBKEY` | `SSH_PUBKEY="ssh-ed25519 AAAA... me@laptop"` | Add this public key without being asked. |
| `PASSWORD_LOGIN` | `PASSWORD_LOGIN=keep` | Never turn off password logins. |
| `OPEN_PORTS` | `OPEN_PORTS="80,443,8080"` | Extra TCP ports to leave open in the firewall. |
| `FIREWALL` | `FIREWALL=no` | Don't touch the firewall (for people who manage their own). |
| `SAFETY_CHECK` | `SAFETY_CHECK=no` | Skip the "did the new login work?" test at the end. |
| `SAFETY_TIMEOUT` | `SAFETY_TIMEOUT=900` | Seconds to wait for that answer before undoing (default 600). |

**Fully unattended** (no questions at all, for example on many servers at once):

```bash
curl -fsSL https://raw.githubusercontent.com/dieselbabyy/protect-yourself/main/protect-yourself.sh \
  | sudo HARDEN=yes GITHUB_USER=yourname SSH_PORT=40022 bash
```

When nobody is there to answer and `HARDEN` isn't set, the script only sets up updates. The login test is also skipped in unattended mode, so pick a fixed `SSH_PORT` you've already opened in your cloud firewall.

---

## Connecting after it runs

Use the command from the report. The important part is `-p` followed by your new port:

```bash
ssh -p 41873 alice@203.0.113.10
# with a key made by option 3:
ssh -i ~/.ssh/protect-yourself_key -p 41873 alice@203.0.113.10
```

To make this easier, add the server to `~/.ssh/config` **on your own computer**:

```
Host myserver
    HostName 203.0.113.10
    User alice
    Port 41873
    IdentityFile ~/.ssh/protect-yourself_key
```

After that, `ssh myserver` is all you need. If you copy files with `scp`, it takes a capital `-P 41873`.

Forgot the port? Use your provider's web console and run `sudo cat /root/protect-yourself-report.txt`.

---

## Running a website or other service?

If a website was already running on ports 80 or 443, those stay open automatically. For anything else, open the port yourself.

**Ubuntu, Debian, Arch (ufw):**

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status            # see what's open
```

**Rocky, Alma, RHEL, Fedora, CentOS, openSUSE (firewalld):**

```bash
sudo firewall-cmd --permanent --add-service=http --add-service=https
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-all   # see what's open
```

You can also choose the ports before you run the script, with `OPEN_PORTS="80,443"`. On cloud servers, remember to open them in the provider's firewall too.

> **Docker users:** Docker sets up its own firewall rules, and ports you publish with `-p` can skip past `ufw`. Bind containers to `127.0.0.1` when they don't need to be public.

---

## Check that it's working

| Check | Command |
|---|---|
| The report | `sudo cat /root/protect-yourself-report.txt` |
| Updates (Ubuntu, Debian) | `systemctl status unattended-upgrades` and `sudo tail /var/log/unattended-upgrades/unattended-upgrades.log` |
| Updates (Rocky, Alma, RHEL, Fedora) | `systemctl list-timers 'dnf*'` |
| Updates (CentOS 7) | `systemctl status yum-cron` |
| Updates (openSUSE, Arch) | `systemctl list-timers 'protect-yourself*'` |
| Updates (Alpine) | `cat /etc/crontabs/root` |
| Firewall | `sudo ufw status` or `sudo firewall-cmd --list-all` |
| fail2ban and banned IPs | `sudo fail2ban-client status sshd` |
| SSH port and password setting | `sudo sshd -T \| grep -Ei '^(port\|passwordauthentication)'` |
| SSH is listening | `sudo ss -tlnp \| grep ssh` |

---

## How to undo things

Run these on the server. If you can't get in over SSH, use your provider's web console.

### Put SSH back on port 22 or turn password logins back on

```bash
sudo rm /etc/ssh/sshd_config.d/00-protect-yourself.conf
# CentOS 7 and other older systems: delete the block between
# "# >>> protect-yourself" and "# <<< protect-yourself" at the top of /etc/ssh/sshd_config instead
sudo sshd -t && sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd
sudo ufw allow 22/tcp                                                           # ufw systems
sudo firewall-cmd --permanent --add-service=ssh && sudo firewall-cmd --reload   # firewalld systems
```

To change **only one thing**, edit that file instead of deleting it. For example, change `PasswordAuthentication no` to `yes`, or edit the `Port` line, then restart SSH. If you change the port, open the new one in the firewall first. On SELinux systems, also run `sudo semanage port -a -t ssh_port_t -p tcp NEWPORT`.

Your original files are saved in `/root/protect-yourself-backup-<date>/`.

### Turn off the firewall

```bash
sudo ufw disable                                          # Ubuntu, Debian, Arch
sudo systemctl disable --now firewalld                    # Rocky, Alma, RHEL, Fedora, openSUSE
```

### Turn off fail2ban

```bash
sudo systemctl disable --now fail2ban
sudo rm /etc/fail2ban/jail.d/protect-yourself.local
```

### Turn off automatic updates

| System | Command |
|---|---|
| Ubuntu, Debian | `sudo rm /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/52protect-yourself` (or `sudo apt remove unattended-upgrades`) |
| Rocky, Alma, RHEL, Fedora | `sudo systemctl disable --now dnf-automatic.timer` (on Fedora 41+, maybe `dnf5-automatic.timer`) |
| CentOS 7 | `sudo systemctl disable --now yum-cron` |
| openSUSE, SLES | `sudo systemctl disable --now protect-yourself-updates.timer` |
| Arch | `sudo systemctl disable --now protect-yourself-download-updates.timer` |
| Alpine | remove the `protect-yourself-updates` line from `/etc/crontabs/root` |

### Turn off the automatic reboot

- **Ubuntu, Debian:** `sudo rm /etc/apt/apt.conf.d/52protect-yourself`
- **Everyone else:** `sudo systemctl disable --now protect-yourself-reboot-check.timer`. If your server doesn't use systemd, delete `/etc/cron.d/protect-yourself-reboot-check` instead.

---

## FAQ and troubleshooting

### Locked out?

Don't panic. The session where you ran the script stays connected, so if it's still open, fix things from there. If it's closed:

1. Log in to your hosting provider's website and open the server's **web console**. It's called Console or Recovery Console on DigitalOcean, Linode, Vultr, and Hetzner, **EC2 Serial Console** or **Session Manager** on AWS, the SSH button in Google Cloud, and Serial console on Azure. The console works even when SSH doesn't.
2. Look up your port with `sudo cat /root/protect-yourself-report.txt`.
3. Follow [Put SSH back on port 22](#put-ssh-back-on-port-22-or-turn-password-logins-back-on) if you want to go back.

### "Connection timed out" on the new port

The most common cause is a cloud firewall outside the server, such as an AWS Security Group, a Google Cloud firewall rule, an Azure NSG, an Oracle Security List, or a DigitalOcean or Hetzner cloud firewall. Add a rule there that allows **TCP** on your new port.

### "Permission denied (publickey)"

- Make sure you're pointing at the right key: `ssh -i ~/.ssh/protect-yourself_key -p PORT user@IP`.
- On Mac and Linux, the key file must be private: `chmod 600 ~/.ssh/protect-yourself_key`.
- Use the same username shown in the report.
- **"Load key: invalid format"** usually means part of the key was missing when you pasted it. The file has to include the `-----BEGIN` and `-----END` lines.

### I banned myself with fail2ban

Wait an hour, or use the web console and run `sudo fail2ban-client set sshd unbanip YOUR.IP.ADDRESS`.

### I use Google Cloud OS Login or AWS EC2 Instance Connect

Those services manage SSH keys their own way, so the script may not see a key and will offer the key menu. If you're happy with how you log in now, choose **Skip** and set `SSH_PORT=keep`.

### Can I run it again?

Yes. It's safe to run more than once. It keeps the port it picked last time and won't add duplicate keys.

### Does it work in Docker or LXC containers?

Mostly no. The updates part works, but firewalls and SSH restarts usually don't inside containers. It's made for real servers and virtual machines.

### Will it break my server?

It tries hard not to, by testing every SSH change, undoing anything that fails, and keeping backups. Still, no script can know every setup. Please test on a server you can afford to rebuild first, and keep your provider's console handy.

---

## Use at your own risk

This script is provided as is, without any warranty. It changes your system's security settings. You're responsible for checking that it suits your server, and for keeping your SSH key and new port somewhere safe.
