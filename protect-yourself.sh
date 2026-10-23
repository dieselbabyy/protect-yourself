#!/usr/bin/env bash
# =============================================================================
# protect-yourself.sh - one command to keep a Linux server patched and locked down.
#
#   curl -fsSL https://raw.githubusercontent.com/dieselbabyy/protect-yourself/main/protect-yourself.sh | sudo bash
#
#   1. Turns on automatic security updates with your distro's own tool.
#   2. Helps you set up an SSH key if you don't have one yet.
#   3. Shows everything the lockdown will change, then asks ONE question.
#   4. Lockdown: firewall, fail2ban, new SSH port, password logins off.
#   5. Prints a report (also saved to /root/protect-yourself-report.txt) and
#      lets you test the new login before keeping it.
#
# Options (environment variables, all optional), e.g.  ... | sudo HARDEN=yes bash
#   REBOOT_TIME=04:00      24h server time to reboot, only if an update needs it
#   HARDEN=yes|no          answer the final question up front (no = updates only)
#   SSH_PORT=number|keep   choose the new SSH port, or keep the current one
#   GITHUB_USER=name       import SSH keys from https://github.com/name.keys
#   SSH_PUBKEY="ssh-ed25519 AAAA..."   add this public key
#   PASSWORD_LOGIN=keep    never turn off password logins
#   OPEN_PORTS="80,443"    extra TCP ports to leave open in the firewall
#   FIREWALL=no            don't touch the firewall (you manage your own)
#   SAFETY_CHECK=no        skip the "test your new login" check at the end
#   SAFETY_TIMEOUT=600     seconds to wait for that check before undoing
# =============================================================================
set -euo pipefail
umask 022

REBOOT_TIME="${REBOOT_TIME:-04:00}"
HARDEN="${HARDEN:-}"
SSH_PORT_REQ="${SSH_PORT:-}"
GITHUB_USER="${GITHUB_USER:-}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
PASSWORD_LOGIN="${PASSWORD_LOGIN:-}"
OPEN_PORTS="${OPEN_PORTS:-}"
FIREWALL="${FIREWALL:-yes}"
SAFETY_CHECK="${SAFETY_CHECK:-yes}"
SAFETY_TIMEOUT="${SAFETY_TIMEOUT:-600}"

LOG=/var/log/protect-yourself.log
REPORT_FILE=/root/protect-yourself-report.txt
DROPIN=/etc/ssh/sshd_config.d/00-protect-yourself.conf
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/protect-yourself-backup-$STAMP"

# ---------- output helpers (colors only on a real terminal) ----------
if [ -t 1 ]; then
  B=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; N=$'\e[0m'
else
  B=""; RED=""; GRN=""; YEL=""; CYN=""; N=""
fi
say()   { printf '%s\n' "$*"; }
title() { printf '\n%s== %s ==%s\n' "$CYN$B" "$*" "$N"; }
ok()    { printf '%s  [OK]%s %s\n' "$GRN" "$N" "$*"; }
warn()  { printf '%s  [!!]%s %s\n' "$YEL" "$N" "$*"; }
die()   { printf '%sERROR:%s %s\n' "$RED" "$N" "$*" >&2; exit 1; }
line()  { printf '%s\n' "=============================================================================="; }
log()   { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
# Run a command quietly, sending its output to the log file.
q()     { log "+ $*"; "$@" >>"$LOG" 2>&1 </dev/null; }

HAVE_TTY=no
ask() { # ask "question" "default" -> prints the answer
  local ans=""
  if [ "$HAVE_TTY" = yes ]; then read -r -p "$1" ans </dev/tty || ans=""; fi
  printf '%s' "${ans:-${2:-}}"
}
yes_no() { [[ "$1" =~ ^[Yy] ]]; }

# ---------- system detection ----------
PM=""; DISTRO=""; HAS_SYSTEMD=no
detect_system() {
  [ -r /etc/os-release ] || die "Can't find /etc/os-release, so I can't tell which Linux this is."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_NAME="${PRETTY_NAME:-$OS_ID}"
  local fam=" ${ID:-} ${ID_LIKE:-} "
  if   [[ "$fam" =~ \ (debian|ubuntu)\  ]]; then DISTRO=debian
  elif [[ "$fam" =~ \ (rhel|fedora|centos|amzn)\  ]]; then DISTRO=rhel
  elif [[ "$fam" =~ (suse|sles) ]]; then DISTRO=suse
  elif [[ "$fam" =~ \ arch\  ]]; then DISTRO=arch
  elif [[ "$fam" =~ \ alpine\  ]]; then DISTRO=alpine
  else die "Sorry, $OS_NAME isn't supported (Ubuntu, Debian, RHEL/Rocky/Alma/Fedora/CentOS, openSUSE/SLES, Arch, Alpine are)."
  fi
  local p; for p in apt-get dnf yum zypper pacman apk; do
    if command -v "$p" >/dev/null 2>&1; then PM="$p"; break; fi
  done
  [ -n "$PM" ] || die "No supported package manager found."
  if [ -d /run/systemd/system ]; then HAS_SYSTEMD=yes; fi
}

pkg_install() {
  case "$PM" in
    apt-get) q env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q "$@" ;;
    dnf)     q dnf -y install "$@" ;;
    yum)     q yum -y install "$@" ;;
    zypper)  q zypper --non-interactive install --no-recommends "$@" ;;
    # Arch: if the package database is missing/stale, do a full upgrade instead
    # of a partial "-Sy" (partial upgrades are unsupported on Arch).
    pacman)  q pacman -S --noconfirm --needed "$@" || q pacman -Syu --noconfirm --needed "$@" ;;
    apk)     q apk add "$@" ;;
  esac
}
have() { command -v "$1" >/dev/null 2>&1; }
svc_enable() { # svc_enable name  (systemd or OpenRC)
  if [ "$HAS_SYSTEMD" = yes ]; then q systemctl enable --now "$1"
  elif have rc-service; then q rc-update add "$1" default; q rc-service "$1" start
  else return 1; fi
}
svc_restart() {
  if [ "$HAS_SYSTEMD" = yes ]; then q systemctl restart "$1"
  elif have rc-service; then q rc-service "$1" restart
  else return 1; fi
}

# make_job NAME SYSTEMD_ONCALENDAR CRON_SCHEDULE PERSISTENT SCRIPT_BODY
# Installs a small script in /usr/local/sbin and runs it on a schedule
# (systemd timer when available, otherwise cron).
make_job() {
  local name="$1" cal="$2" cron="$3" persist="$4" body="$5"
  local bin="/usr/local/sbin/protect-yourself-$name"
  mkdir -p /usr/local/sbin
  printf '#!/bin/sh\n# Created by protect-yourself.sh. Remove with the steps in the README.\n%s\n' "$body" >"$bin"
  chmod 755 "$bin"
  if [ "$HAS_SYSTEMD" = yes ]; then
    printf '[Unit]\nDescription=protect-yourself: %s\n\n[Service]\nType=oneshot\nExecStart=%s\n' \
      "$name" "$bin" >"/etc/systemd/system/protect-yourself-$name.service"
    printf '[Unit]\nDescription=protect-yourself: %s schedule\n\n[Timer]\nOnCalendar=%s\nPersistent=%s\n\n[Install]\nWantedBy=timers.target\n' \
      "$name" "$cal" "$persist" >"/etc/systemd/system/protect-yourself-$name.timer"
    q systemctl daemon-reload && q systemctl enable --now "protect-yourself-$name.timer"
  elif [ -d /etc/crontabs ]; then   # Alpine / busybox cron
    touch /etc/crontabs/root
    sed -i "\#$bin#d" /etc/crontabs/root
    printf '%s %s >>/var/log/protect-yourself-%s.log 2>&1\n' "$cron" "$bin" "$name" >>/etc/crontabs/root
  else
    mkdir -p /etc/cron.d
    printf '%s root %s >>/var/log/protect-yourself-%s.log 2>&1\n' "$cron" "$bin" "$name" >"/etc/cron.d/protect-yourself-$name"
    have crond || have cron || warn "No cron program found; install cron so the '$name' job runs."
  fi
}

# ======================= STEP 1: automatic updates ===========================
UPD_TOOL="not set up"; UPD_SCHEDULE=""; REBOOT_DESC="none"
RB_H=4; RB_M=0

setup_updates_debian() {
  q apt-get -o DPkg::Lock::Timeout=300 update -q || return 1
  pkg_install unattended-upgrades || return 1
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<CONF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
  cat >/etc/apt/apt.conf.d/52protect-yourself <<CONF
// Added by protect-yourself.sh
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Dpkg::Options { "--force-confdef"; "--force-confold"; };
CONF
  rm -f /etc/apt/apt.conf.d/52auto-reboot   # file name used by older versions of this script
  if [ "$HAS_SYSTEMD" = yes ]; then
    q systemctl enable --now apt-daily.timer apt-daily-upgrade.timer || true
    q systemctl enable --now unattended-upgrades || true
  fi
  q unattended-upgrade --dry-run || warn "unattended-upgrades dry run reported a problem (see $LOG)."
  UPD_TOOL="unattended-upgrades"; UPD_SCHEDULE="security updates, daily"
  REBOOT_DESC="at $REBOOT_TIME, only when an update needs it"
}

setup_updates_dnf() {
  local dnf5=no; if dnf --version 2>/dev/null | grep -qi dnf5; then dnf5=yes; fi
  pkg_install dnf-automatic || pkg_install dnf5-plugin-automatic || return 1
  if [ "$dnf5" = yes ]; then pkg_install dnf5-plugins || true; else pkg_install dnf-plugins-core || true; fi
  # Repos with security metadata: RHEL, Rocky, Alma, Oracle, Amazon. Fedora and
  # CentOS Stream have none, so "security only" would install nothing there.
  local type=default
  case "$OS_ID" in rhel|rocky|almalinux|ol|amzn) type=security ;; esac
  local conf=/etc/dnf/automatic.conf
  if [ -f "$conf" ]; then cp -a "$conf" "$conf.bak-protect-yourself"; fi
  mkdir -p /etc/dnf
  cat >"$conf" <<CONF
# Written by protect-yourself.sh (old file saved as automatic.conf.bak-protect-yourself)
[commands]
upgrade_type = $type
random_sleep = 0
download_updates = yes
apply_updates = yes

[emitters]
emit_via = stdio
CONF
  local t done_timer=no
  if [ "$HAS_SYSTEMD" = yes ]; then
    for t in dnf-automatic.timer dnf5-automatic.timer; do
      if q systemctl enable --now "$t"; then done_timer=yes; break; fi
    done
    [ "$done_timer" = yes ] || { warn "Could not start the dnf-automatic timer."; return 1; }
  fi
  # shellcheck disable=SC2016  # the job script is written literally on purpose
  make_job reboot-check "*-*-* ${RB_H}:${RB_M}:00" "$RB_M $RB_H * * *" false \
'out=$(dnf needs-restarting -r 2>&1); rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qi "reboot is required"; then /sbin/shutdown -r +1 "protect-yourself: rebooting to finish updates"; fi' || true
  UPD_TOOL="dnf-automatic"
  if [ "$type" = security ]; then UPD_SCHEDULE="security updates, daily"; else UPD_SCHEDULE="all updates, daily; this distro has no security-only list"; fi
  REBOOT_DESC="at $REBOOT_TIME, only when an update needs it"
}

setup_updates_yum() {
  pkg_install yum-cron yum-utils || return 1
  local type=security
  case "$OS_ID" in centos) type=default ;; esac   # CentOS repos have no security metadata
  sed -i "s/^update_cmd.*/update_cmd = $type/; s/^apply_updates.*/apply_updates = yes/" /etc/yum/yum-cron.conf || return 1
  svc_enable yum-cron || return 1
  # shellcheck disable=SC2016
  make_job reboot-check "*-*-* ${RB_H}:${RB_M}:00" "$RB_M $RB_H * * *" false \
'out=$(needs-restarting -r 2>&1); rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -qi "reboot is required"; then /sbin/shutdown -r +1 "protect-yourself: rebooting to finish updates"; fi' || true
  UPD_TOOL="yum-cron"; UPD_SCHEDULE="$( [ "$type" = security ] && echo "security updates" || echo "all updates" ), daily"
  REBOOT_DESC="at $REBOOT_TIME, only when an update needs it"
}

setup_updates_suse() {
  make_job updates "*-*-* 00/4:15:00" "15 */4 * * *" true \
'zypper --non-interactive --quiet refresh
zypper --non-interactive patch --category security --auto-agree-with-licenses
# 103 = zypper updated itself and wants a second run
[ $? -eq 103 ] && zypper --non-interactive patch --category security --auto-agree-with-licenses
exit 0' || return 1
  make_job reboot-check "*-*-* ${RB_H}:${RB_M}:00" "$RB_M $RB_H * * *" false \
'zypper needs-rebooting >/dev/null 2>&1
[ $? -eq 102 ] && /sbin/shutdown -r +1 "protect-yourself: rebooting to finish updates"
exit 0' || true
  UPD_TOOL="zypper security patches"; UPD_SCHEDULE="every 4 hours"
  REBOOT_DESC="at $REBOOT_TIME, only when an update needs it"
}

setup_updates_arch() {
  # Unattended full upgrades can break Arch, and "pacman -Syuw" leaves a
  # half-synced database. checkupdates -d downloads safely into the cache.
  pkg_install pacman-contrib || return 1
  make_job download-updates "*-*-* 00/4:15:00" "15 */4 * * *" true 'checkupdates -d; exit 0' || return 1
  UPD_TOOL="download only (checkupdates)"; UPD_SCHEDULE="every 4 hours; install them yourself with: sudo pacman -Syu"
  REBOOT_DESC="none (Arch: you install and reboot yourself)"
}

setup_updates_alpine() {
  make_job updates "*-*-* 00/4:15:00" "15 */4 * * *" true 'apk update -q && apk upgrade -q' || return 1
  if have rc-service; then q rc-update add crond default || true; q rc-service crond start || true; fi
  UPD_TOOL="apk upgrade (cron)"; UPD_SCHEDULE="every 4 hours"
  REBOOT_DESC="none (reboot yourself after kernel updates)"
}

setup_updates() {
  title "Step 1 of 3: automatic security updates"
  say "Setting up $OS_NAME's own update tool. This can take a few minutes..."
  local fn
  case "$DISTRO:$PM" in
    debian:*) fn=setup_updates_debian ;;
    rhel:dnf) fn=setup_updates_dnf ;;
    rhel:yum) fn=setup_updates_yum ;;
    suse:*)   fn=setup_updates_suse ;;
    arch:*)   fn=setup_updates_arch ;;
    alpine:*) fn=setup_updates_alpine ;;
    *) warn "No update setup for $DISTRO with $PM."; return 0 ;;
  esac
  if "$fn"; then
    ok "Automatic updates are on: $UPD_TOOL ($UPD_SCHEDULE)."
    ok "Reboots: $REBOOT_DESC."
  else
    UPD_TOOL="FAILED"; UPD_SCHEDULE="see $LOG"; REBOOT_DESC="not set up"
    warn "Automatic updates could not be fully set up. Details are in $LOG."
  fi
}

# ======================= helpers for the lockdown ============================
http_get() {
  if have curl; then curl -fsSL --max-time 10 "$1"
  elif have wget; then wget -qO- --timeout=10 "$1"
  else return 1; fi
}
port_in_use() { # 0 = something listens on TCP port $1
  if have ss; then [ -n "$(ss -Htln "sport = :$1" 2>/dev/null)" ]
  elif have netstat; then netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
  else return 1; fi
}
sshd_listening() { # 0 = sshd listens on port $1 (waits up to 10s)
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if have ss; then
      if ss -Htlnp "sport = :$1" 2>/dev/null | grep -q sshd; then return 0; fi
      # -p may show nothing in some containers; fall back to "anything listens"
      if ss -Htlnp "sport = :$1" 2>/dev/null | grep -qv users: && port_in_use "$1"; then return 0; fi
    elif port_in_use "$1"; then return 0; fi
    sleep 1
  done
  return 1
}
random_port() {
  local p _
  for _ in $(seq 1 100); do
    p=$(( 20000 + (RANDOM * 32768 + RANDOM) % 40001 ))
    case "$p" in 25565|27017|27018|32400|50000) continue ;; esac   # popular app ports
    if ! port_in_use "$p"; then echo "$p"; return 0; fi
  done
  return 1
}
public_ip() {
  local ip
  ip="$(http_get https://api.ipify.org 2>/dev/null || true)"
  if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then echo "$ip"; return; fi
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "${ip:-YOUR-SERVER-IP}"
}
cloud_name() {
  local v
  v="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/bios_version \
        /sys/class/dmi/id/chassis_asset_tag 2>/dev/null | tr '\n' ' ' || true)"
  case "$v" in
    *[Aa]mazon*)    echo "AWS (Security Group)" ;;
    *Google*)       echo "Google Cloud (VPC firewall rules)" ;;
    *OracleCloud*)  echo "Oracle Cloud (Security List)" ;;
    *Microsoft*)    echo "Azure (Network Security Group)" ;;
    *) echo "" ;;
  esac
}
listening_ports() { # public TCP ports something is listening on
  have ss || return 0
  ss -Htln 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|::1)' \
    | sed -E 's/.*://' | grep -E '^[0-9]+$' | sort -un || true
}
KEY_RE='(^|[ ,])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) AAAA[A-Za-z0-9+/=]+'
usable_keys_in() { # count login-capable keys in an authorized_keys file
  [ -f "$1" ] || { echo 0; return; }
  grep -E "$KEY_RE" "$1" 2>/dev/null | grep -vc 'command=' || true
}
valid_pubkey() { # 0 = $1 is a single valid public key line
  local k="$1" t
  [[ "$k" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ AAAA[A-Za-z0-9+/=]+(\ .*)?$ ]] || return 1
  have ssh-keygen || return 0
  t="$(mktemp)"; printf '%s\n' "$k" >"$t"
  if ssh-keygen -lf "$t" >/dev/null 2>&1; then rm -f "$t"; return 0; fi
  rm -f "$t"; return 1
}
selinux_on() { have getenforce && [ "$(getenforce 2>/dev/null)" != Disabled ]; }

# Backups so every SSH change can be undone.
BACKED_UP=()
backup_file() {
  local f="$1"; [ -e "$f" ] || return 0
  mkdir -p "$BACKUP_DIR$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR$f"; BACKED_UP+=("$f")
}
restore_backups() {
  local f
  for f in "${BACKED_UP[@]+"${BACKED_UP[@]}"}"; do cp -a "$BACKUP_DIR$f" "$f" 2>/dev/null || true; done
}

# ======================= STEP 2: plan the lockdown ===========================
SSHD=""; SSH_SVC=""; LOGIN_USER=""; LOGIN_HOME=""; AUTH_KEYS=""
OLD_PORT=22; NEW_PORT=""; FW=none; KEEP_OPEN=()
EXISTING_KEYS=0; PENDING_KEYS=""; KEY_PLAN=""; KEY_SOURCE=""; KEY_FILE_HINT=""
PASSWORDS_OFF=no; CLOUD=""; SERVER_IP=""

plan_lockdown() {
  title "Step 2 of 3: SSH keys"
  say "Nothing changes on this step until you confirm at the end."
  SSHD="$(command -v sshd || true)"; [ -n "$SSHD" ] || { [ -x /usr/sbin/sshd ] && SSHD=/usr/sbin/sshd; } || true
  LOGIN_USER="${SUDO_USER:-root}"
  [ -n "$LOGIN_USER" ] || LOGIN_USER=root
  LOGIN_HOME="$(getent passwd "$LOGIN_USER" 2>/dev/null | cut -d: -f6 || true)"
  [ -n "$LOGIN_HOME" ] || { LOGIN_USER=root; LOGIN_HOME=/root; }
  AUTH_KEYS="$LOGIN_HOME/.ssh/authorized_keys"
  SERVER_IP="$(public_ip)"
  CLOUD="$(cloud_name)"

  if [ -z "$SSHD" ]; then
    warn "No SSH server (sshd) found, so SSH keys, port and password settings are skipped."
  else
    mkdir -p /run/sshd 2>/dev/null || true
    OLD_PORT="$("$SSHD" -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"; OLD_PORT="${OLD_PORT:-22}"
    if [ "$HAS_SYSTEMD" = yes ]; then
      if systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh\.service'; then SSH_SVC=ssh; else SSH_SVC=sshd; fi
    else SSH_SVC=sshd; fi

    # New port: keep a port that's already non-default, unless SSH_PORT says otherwise.
    if [ "$SSH_PORT_REQ" = keep ]; then NEW_PORT=""
    elif [ -n "$SSH_PORT_REQ" ]; then
      if ! [[ "$SSH_PORT_REQ" =~ ^[0-9]+$ ]] || [ "$SSH_PORT_REQ" -lt 1024 ] || [ "$SSH_PORT_REQ" -gt 65535 ]; then
        die "SSH_PORT must be a number from 1024 to 65535 (or 'keep')."
      fi
      if [ "$SSH_PORT_REQ" != "$OLD_PORT" ]; then
        port_in_use "$SSH_PORT_REQ" && die "Port $SSH_PORT_REQ is already in use by another program."
        NEW_PORT="$SSH_PORT_REQ"
      fi
    elif [ "$OLD_PORT" = 22 ]; then
      NEW_PORT="$(random_port || true)"
    fi

    EXISTING_KEYS="$(usable_keys_in "$AUTH_KEYS")"
    if [ "$EXISTING_KEYS" -gt 0 ]; then
      ok "User '$LOGIN_USER' already has $EXISTING_KEYS SSH key(s) set up."
      KEY_PLAN="already set up ($EXISTING_KEYS key(s) for $LOGIN_USER)"
    else
      key_menu
    fi
  fi

  if [ -n "$SSHD" ] && [ "$PASSWORD_LOGIN" != keep ] && { [ "$EXISTING_KEYS" -gt 0 ] || [ -n "$PENDING_KEYS" ]; }; then
    PASSWORDS_OFF=yes
  fi

  # Firewall choice
  if have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then FW=ufw
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then FW=firewalld
  else case "$DISTRO" in rhel|suse) FW=firewalld ;; debian|arch) FW=ufw ;; *) FW=none ;; esac; fi
  [ "$HAS_SYSTEMD" = yes ] || [ "$FW" != firewalld ] || FW=none   # firewalld needs systemd
  if [[ "$FIREWALL" =~ ^[Nn] ]]; then FW=none; fi

  # Ports to keep open besides SSH: OPEN_PORTS plus any website already running.
  local p listening
  listening="$(listening_ports)"
  for p in 80 443; do
    if grep -qx "$p" <<<"$listening"; then KEEP_OPEN+=("$p"); fi
  done
  for p in ${OPEN_PORTS//,/ }; do
    [[ "$p" =~ ^[0-9]+$ ]] && KEEP_OPEN+=("$p")
  done
  if [ ${#KEEP_OPEN[@]} -gt 0 ]; then
    mapfile -t KEEP_OPEN < <(printf '%s\n' "${KEEP_OPEN[@]}" | sort -un)
  fi
}

add_pending_key() { # add_pending_key "line" -> 0 if valid
  if valid_pubkey "$1"; then PENDING_KEYS+="$1"$'\n'; return 0; fi
  return 1
}

import_github() {
  local user="$1" keys k n=0
  [[ "$user" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || { warn "'$user' isn't a valid GitHub username."; return 1; }
  keys="$(http_get "https://github.com/$user.keys" 2>/dev/null || true)"
  while IFS= read -r k; do
    k="${k%$'\r'}"; [ -n "$k" ] || continue
    if add_pending_key "$k"; then n=$((n + 1)); fi
  done <<<"$keys"
  if [ "$n" -eq 0 ]; then
    warn "No SSH keys found at https://github.com/$user.keys (add one at github.com/settings/keys)."
    return 1
  fi
  ok "Found $n key(s) on GitHub for '$user'."
  KEY_PLAN="add $n key(s) from github.com/$user"; KEY_SOURCE=github
}

generate_key() {
  local d; d="$(mktemp -d)"; chmod 700 "$d"
  if ! ssh-keygen -q -t ed25519 -N "" -C "protect-yourself@${HOSTNAME:-server}" -f "$d/key" </dev/null >/dev/null 2>&1; then
    rm -rf "$d"; warn "Couldn't create a key."; return 1
  fi
  add_pending_key "$(cat "$d/key.pub")" || { rm -rf "$d"; return 1; }
  local port="${NEW_PORT:-$OLD_PORT}"
  {
    printf '\n%s' "$YEL$B"; line
    say "  YOUR NEW PRIVATE KEY - this is shown ONCE and is NOT kept on the server."
    say "  Anyone who has it can log in to this server. Keep it secret."
    line; printf '%s' "$N"
    cat "$d/key"
    line
    say "  Copy everything from -----BEGIN to END-----, including those two lines."
    say ""
    say "  ${B}Mac or Linux${N} (open the Terminal app on YOUR computer):"
    say "    1. mkdir -p ~/.ssh && nano ~/.ssh/protect-yourself_key"
    say "    2. Paste the key, then press Ctrl+O, Enter, Ctrl+X to save."
    say "    3. chmod 600 ~/.ssh/protect-yourself_key"
    say "    4. Connect later with:"
    say "       ssh -i ~/.ssh/protect-yourself_key -p $port $LOGIN_USER@$SERVER_IP"
    say ""
    say "  ${B}Windows 10/11${N} (copy the key first, then open PowerShell on YOUR computer):"
    say "    1. mkdir -Force \$HOME\\.ssh"
    say "    2. Set-Content -NoNewline -Encoding ascii \$HOME\\.ssh\\protect-yourself_key ((Get-Clipboard -Raw).Replace(\"\`r\",\"\").Trim() + \"\`n\")"
    say "    3. icacls \$HOME\\.ssh\\protect-yourself_key /inheritance:r /grant:r \"\${env:USERNAME}:F\""
    say "    4. Connect later with:"
    say "       ssh -i \$HOME\\.ssh\\protect-yourself_key -p $port $LOGIN_USER@$SERVER_IP"
    say "    (PuTTY users: open PuTTYgen > Conversions > Import key, then Save private key.)"
    line
  } >/dev/tty
  ask "Press Enter once you've saved the key on your computer... " "" >/dev/null
  rm -f "$d/key"; rm -rf "$d"
  printf '\n\n\n' >/dev/tty
  ok "Private key deleted from the server. Only you have it now."
  KEY_PLAN="add the new key you just saved"; KEY_SOURCE=generated
  KEY_FILE_HINT="-i ~/.ssh/protect-yourself_key "
}

key_menu() {
  # Unattended: take keys from the environment.
  if [ -n "$GITHUB_USER" ]; then import_github "$GITHUB_USER" || true; fi
  if [ -n "$SSH_PUBKEY" ]; then
    if add_pending_key "$SSH_PUBKEY"; then KEY_PLAN="${KEY_PLAN:+$KEY_PLAN + }add the key from SSH_PUBKEY"; KEY_SOURCE=pasted
    else warn "SSH_PUBKEY doesn't look like a valid public key; ignoring it."; fi
  fi
  [ -z "$PENDING_KEYS" ] || return 0
  if [ "$HAVE_TTY" != yes ]; then
    KEY_PLAN="none found (password logins stay on)"; return 0
  fi
  say ""
  say "User '${B}$LOGIN_USER${N}' has no SSH key yet. Keys are much safer than passwords,"
  say "and password logins can only be turned off once a key works. Pick one:"
  say ""
  say "  1) Import my key from GitHub        (if your GitHub account has an SSH key)"
  say "  2) Paste a public key I already have (one line starting with ssh-ed25519 or ssh-rsa)"
  say "  3) Make a new key for me             (recommended if you're not sure)"
  say "  4) Skip                              (keep password logins on)"
  local choice tries=0 k
  while [ -z "$PENDING_KEYS" ] && [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    choice="$(ask "Choose 1-4 [3]: " 3)"
    case "$choice" in
      1) k="$(ask "Your GitHub username: " "")"; import_github "$k" || true ;;
      2) k="$(ask "Paste the public key, then press Enter: " "")"
         k="$(printf '%s' "$k" | tr -d '\r' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
         if add_pending_key "$k"; then ok "Key accepted."; KEY_PLAN="add the key you pasted"; KEY_SOURCE=pasted
         else warn "That doesn't look like a public key (it should start with ssh-ed25519 or ssh-rsa, and is NOT the private key)."; fi ;;
      3) generate_key || true ;;
      4) break ;;
      *) warn "Please type 1, 2, 3 or 4." ;;
    esac
  done
  [ -n "$PENDING_KEYS" ] || KEY_PLAN="none (password logins stay on)"
}

show_summary() {
  title "Step 3 of 3: review the lockdown"
  local fwdesc keep="" pw other p
  if [ ${#KEEP_OPEN[@]} -gt 0 ]; then keep=" + ${KEEP_OPEN[*]}"; fi
  case "$FW" in
    ufw|firewalld) fwdesc="$FW ON: block all incoming except SSH (port ${NEW_PORT:-$OLD_PORT})$keep" ;;
    *) if [[ "$FIREWALL" =~ ^[Nn] ]]; then fwdesc="not touched (FIREWALL=no)"; else fwdesc="skipped (no supported firewall on $OS_NAME)"; fi ;;
  esac
  if [ "$PASSWORDS_OFF" = yes ]; then pw="OFF (key-only logins; root can only log in with a key)"
  else pw="stay ON (no SSH key set up)"; fi
  line
  say "  ${B}HERE IS WHAT WILL CHANGE IF YOU SAY YES${N}"
  line
  printf '  %-18s %s\n' "Updates:" "$UPD_TOOL - already done"
  printf '  %-18s %s\n' "Firewall:" "$fwdesc"
  printf '  %-18s %s\n' "fail2ban:" "install; ban an IP for 1 hour after 5 failed logins"
  if [ -n "$SSHD" ]; then
    printf '  %-18s %s\n' "SSH key:" "$KEY_PLAN"
    if [ -n "$NEW_PORT" ]; then printf '  %-18s %s\n' "SSH port:" "$OLD_PORT -> ${B}$NEW_PORT${N}  (write this down)"
    else printf '  %-18s %s\n' "SSH port:" "stays $OLD_PORT"; fi
    printf '  %-18s %s\n' "Password logins:" "$pw"
  fi
  other=""
  if [ "$FW" != none ]; then
    for p in $(listening_ports); do
      [ "$p" = "$OLD_PORT" ] && continue
      printf '%s\n' "${KEEP_OPEN[@]+"${KEEP_OPEN[@]}"}" | grep -qx "$p" && continue
      other+="$p "
    done
  fi
  if [ -n "$other" ]; then
    say ""
    warn "These ports are in use and will be BLOCKED from the internet: $other"
    say "       To keep them open, answer N and run again with OPEN_PORTS=\"${other// /,}\" (see README)."
  fi
  if [ -n "$NEW_PORT" ]; then
    say ""
    if [ -n "$CLOUD" ]; then
      warn "This looks like a ${B}$CLOUD${N} server. Its own firewall blocks new ports."
      warn "Open TCP port $NEW_PORT there FIRST, or new logins will fail."
    else
      warn "If your provider has its own firewall (AWS, Google Cloud, Azure, Oracle,"
      warn "DigitalOcean/Hetzner/Vultr cloud firewalls), open TCP port $NEW_PORT there first."
    fi
  fi
  line
}

# ======================= STEP 3: apply the lockdown ==========================
FW_OK=no; KEY_OK=no; PORT_OK=no; PW_OK=no; SOCKET_CHANGED=no
FW_RESULT="not changed"; F2B_RESULT="not installed"; KEY_RESULT="not changed"; SSH_RESULT="not changed"

install_keys() {
  [ -n "$PENDING_KEYS" ] || { [ "$EXISTING_KEYS" -gt 0 ] && KEY_OK=yes; KEY_RESULT="${KEY_PLAN}"; fix_ssh_perms; return 0; }
  local grp k n=0
  grp="$(id -gn "$LOGIN_USER" 2>/dev/null || echo "$LOGIN_USER")"
  mkdir -p "$LOGIN_HOME/.ssh"
  touch "$AUTH_KEYS"
  mkdir -p "$BACKUP_DIR$LOGIN_HOME/.ssh"; cp -a "$AUTH_KEYS" "$BACKUP_DIR$AUTH_KEYS" 2>/dev/null || true   # kept, not auto-restored
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    grep -qxF "$k" "$AUTH_KEYS" || { printf '%s\n' "$k" >>"$AUTH_KEYS"; n=$((n + 1)); }
  done <<<"$PENDING_KEYS"
  chown "$LOGIN_USER:$grp" "$LOGIN_HOME/.ssh" "$AUTH_KEYS" 2>/dev/null || true
  fix_ssh_perms
  if [ "$(usable_keys_in "$AUTH_KEYS")" -gt 0 ]; then
    KEY_OK=yes; KEY_RESULT="installed for $LOGIN_USER ($KEY_SOURCE, $n new)"
    ok "SSH key installed for $LOGIN_USER."
  else
    KEY_RESULT="FAILED to install"; warn "Could not install the SSH key."
  fi
}
fix_ssh_perms() {
  [ -d "$LOGIN_HOME/.ssh" ] || return 0
  chmod go-w "$LOGIN_HOME" 2>/dev/null || true      # sshd ignores keys if home is group/world-writable
  chmod 700 "$LOGIN_HOME/.ssh" 2>/dev/null || true
  [ -f "$AUTH_KEYS" ] && chmod 600 "$AUTH_KEYS" 2>/dev/null
  if selinux_on && have restorecon; then q restorecon -R "$LOGIN_HOME/.ssh" || true; fi
  return 0
}

fw_open() { # fw_open PORT
  case "$FW" in
    ufw) q ufw allow "$1/tcp" ;;
    firewalld) q firewall-cmd --permanent --add-port="$1/tcp" && q firewall-cmd --reload ;;
    *) return 0 ;;
  esac
}
fw_close() { # fw_close PORT
  case "$FW" in
    ufw) q ufw delete allow "$1/tcp" || true ;;
    firewalld)
      q firewall-cmd --permanent --remove-port="$1/tcp" || true
      if [ "$1" = 22 ]; then q firewall-cmd --permanent --remove-service=ssh || true; fi
      q firewall-cmd --reload || true ;;
  esac
}
setup_firewall() {
  local p
  case "$FW" in
    ufw)
      have ufw || pkg_install ufw || return 1
      q ufw allow "$OLD_PORT/tcp" || return 1
      if [ -n "$NEW_PORT" ]; then q ufw allow "$NEW_PORT/tcp" || return 1; fi
      for p in "${KEEP_OPEN[@]+"${KEEP_OPEN[@]}"}"; do q ufw allow "$p/tcp" || true; done
      q ufw default deny incoming && q ufw default allow outgoing || return 1
      q ufw --force enable || return 1
      if [ "$HAS_SYSTEMD" = yes ]; then q systemctl enable ufw || true; fi
      ;;
    firewalld)
      have firewall-cmd || pkg_install firewalld || return 1
      q systemctl enable --now firewalld || return 1
      q firewall-cmd --permanent --add-port="$OLD_PORT/tcp" || return 1
      if [ -n "$NEW_PORT" ]; then q firewall-cmd --permanent --add-port="$NEW_PORT/tcp" || return 1; fi
      for p in "${KEEP_OPEN[@]+"${KEEP_OPEN[@]}"}"; do q firewall-cmd --permanent --add-port="$p/tcp" || true; done
      q firewall-cmd --reload || return 1
      ;;
    *) return 1 ;;
  esac
}
firewall_active() {
  { have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; } || { have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; }
}

F2B_JAIL=/etc/fail2ban/jail.d/protect-yourself.local
write_f2b_jail() { # write_f2b_jail "PORTS"
  local backend=auto extra=""
  if [ "$HAS_SYSTEMD" = yes ]; then backend=systemd; fi
  if [ "$DISTRO" = alpine ]; then extra=$'logpath = /var/log/messages\n'; fi
  mkdir -p /etc/fail2ban/jail.d
  printf '# Added by protect-yourself.sh\n[sshd]\nenabled = true\nport = %s\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\nbackend = %s\n%s' \
    "$1" "$backend" "$extra" >"$F2B_JAIL"
}
setup_fail2ban() {
  [ -n "$SSHD" ] || return 1
  case "$PM" in
    dnf|yum)
      if ! "$PM" -q info fail2ban >/dev/null 2>&1 </dev/null; then
        pkg_install epel-release || {
          local v; v="$(rpm -E %rhel 2>/dev/null || true)"
          [[ "$v" =~ ^[0-9]+$ ]] && pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$v.noarch.rpm"
        } || true
      fi
      pkg_install fail2ban || return 1
      if [ "$HAS_SYSTEMD" = yes ]; then pkg_install fail2ban-systemd || pkg_install python3-systemd || true; fi ;;
    apt-get) pkg_install fail2ban || return 1; pkg_install python3-systemd || true ;;
    zypper)  pkg_install fail2ban || return 1; pkg_install python3-systemd || true ;;
    pacman)  pkg_install fail2ban || return 1; pkg_install python-systemd || true ;;
    apk)     pkg_install fail2ban || return 1 ;;
  esac
  write_f2b_jail "$OLD_PORT${NEW_PORT:+,$NEW_PORT}"
  svc_enable fail2ban || true
  svc_restart fail2ban || return 1
  sleep 2
  q fail2ban-client status sshd || return 1
}

ssh_restart() {
  if [ "$HAS_SYSTEMD" = yes ]; then q systemctl restart "$SSH_SVC"
  elif have rc-service; then q rc-service sshd restart
  else return 1; fi
}
socket_activated() { # Ubuntu 22.10+ starts sshd from ssh.socket
  [ "$HAS_SYSTEMD" = yes ] || return 1
  systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1
}
use_plain_ssh_service() {
  # Switch from ssh.socket to a normal ssh.service so sshd_config's Port is used.
  local f
  for f in /etc/systemd/system/ssh.service.d/00-socket.conf /etc/systemd/system/ssh.socket.d/addresses.conf; do
    # Copied to the backup folder but not restored on undo: plain ssh.service works with any port.
    if [ -e "$f" ]; then mkdir -p "$BACKUP_DIR$(dirname "$f")"; cp -a "$f" "$BACKUP_DIR$f"; rm -f "$f"; fi
  done
  q systemctl disable --now ssh.socket || true
  q systemctl daemon-reload || true
  q systemctl enable ssh.service || true
  SOCKET_CHANGED=yes
}

write_sshd_settings() {
  local cfg=/etc/ssh/sshd_config f body
  body="# Added by protect-yourself.sh on $(date '+%F %T'). Delete this block/file and restart SSH to undo."$'\n'
  if [ -n "$NEW_PORT" ]; then body+="Port $NEW_PORT"$'\n'
  else
    # Re-run: keep a port this script set earlier.
    f="$( { grep -iE '^Port[[:space:]]' "$DROPIN" 2>/dev/null; sed -n '/^# >>> protect-yourself/,/^# <<< protect-yourself/p' "$cfg" | grep -iE '^Port[[:space:]]'; } | head -n1 || true)"
    if [ -n "$f" ]; then body+="$f"$'\n'; fi
  fi
  if [ "$PASSWORDS_OFF" = yes ] && [ "$KEY_OK" = yes ]; then
    body+=$'PubkeyAuthentication yes\nPasswordAuthentication no\nChallengeResponseAuthentication no\nPermitRootLogin prohibit-password\n'
  fi
  backup_file "$cfg"
  # "Port" lines add up instead of overriding, so comment out all the others.
  if [ -n "$NEW_PORT" ]; then
    for f in "$cfg" /etc/ssh/sshd_config.d/*.conf; do
      if [ ! -f "$f" ] || [ "$f" = "$DROPIN" ]; then continue; fi
      if grep -qiE '^[[:space:]]*Port[[:space:]]' "$f"; then
        backup_file "$f"; sed -i -E 's/^([[:space:]]*[Pp]ort[[:space:]].*)$/# \1  # disabled by protect-yourself.sh/' "$f"
      fi
    done
  fi
  if grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$cfg"; then
    # Drop-in file: sshd uses the first value it reads, and 00- is read first.
    if [ -e "$DROPIN" ]; then backup_file "$DROPIN"; fi
    printf '%s' "$body" >"$DROPIN"; chmod 600 "$DROPIN"
  else
    # No drop-in support (e.g. CentOS 7): put the block at the TOP of sshd_config
    # (before any "Match" sections). The original is backed up.
    sed -i '/^# >>> protect-yourself/,/^# <<< protect-yourself/d' "$cfg"
    { printf '# >>> protect-yourself\n%s# <<< protect-yourself\n' "$body"; cat "$cfg"; } >"$cfg.new" && cat "$cfg.new" >"$cfg" && rm -f "$cfg.new"
  fi
}

undo_ssh() { # put SSH back the way it was
  rm -f "$DROPIN"
  restore_backups
  if [ -n "$NEW_PORT" ] && [ "$HAS_SYSTEMD" = yes ]; then q systemctl daemon-reload || true; fi
  ssh_restart || true
  if [ -n "$NEW_PORT" ]; then
    fw_open "$OLD_PORT" || true
    if [ -f "$F2B_JAIL" ]; then write_f2b_jail "$OLD_PORT"; svc_restart fail2ban || true; fi
  fi
  return 0
}

configure_ssh() {
  [ -n "$SSHD" ] || return 0
  # If a firewall is running and we couldn't open the new port, don't move SSH.
  if [ -n "$NEW_PORT" ] && [ "$FW_OK" != yes ] && firewall_active; then
    warn "Firewall is on but port $NEW_PORT couldn't be opened; keeping SSH on port $OLD_PORT."
    NEW_PORT=""
  fi
  if [ -n "$NEW_PORT" ] && selinux_on; then
    have semanage || pkg_install policycoreutils-python-utils || pkg_install policycoreutils-python || true
    if ! { q semanage port -a -t ssh_port_t -p tcp "$NEW_PORT" || q semanage port -m -t ssh_port_t -p tcp "$NEW_PORT"; }; then
      warn "SELinux won't allow port $NEW_PORT; keeping SSH on port $OLD_PORT."
      NEW_PORT=""
    fi
  fi
  if [ -z "$NEW_PORT" ] && { [ "$PASSWORDS_OFF" != yes ] || [ "$KEY_OK" != yes ]; }; then
    SSH_RESULT="not changed"; return 0
  fi
  if [ -n "$NEW_PORT" ] && socket_activated; then use_plain_ssh_service; fi
  write_sshd_settings

  local reason=""
  if ! "$SSHD" -t >>"$LOG" 2>&1; then reason="the new SSH settings failed the safety test (sshd -t)"
  elif ! ssh_restart; then reason="SSH didn't restart"
  elif [ -n "$NEW_PORT" ] && ! sshd_listening "$NEW_PORT"; then reason="SSH isn't answering on port $NEW_PORT"
  elif [ -z "$NEW_PORT" ] && ! sshd_listening "$OLD_PORT"; then reason="SSH isn't answering on port $OLD_PORT after the restart"
  fi
  if [ -n "$reason" ]; then
    warn "Undoing SSH changes: $reason. SSH stays on port $OLD_PORT."
    undo_ssh; SSH_RESULT="NOT changed ($reason)"; NEW_PORT=""; return 1
  fi
  if [ -n "$NEW_PORT" ]; then
    PORT_OK=yes; ok "SSH is now listening on port $NEW_PORT."
  fi
  if [ "$PASSWORDS_OFF" = yes ] && [ "$KEY_OK" = yes ]; then PW_OK=yes; ok "Password logins are off (keys only)."; fi
  SSH_RESULT="updated"
}

finish_port_move() { # close the old port now that the new one works
  [ "$PORT_OK" = yes ] || return 0
  fw_close "$OLD_PORT"
  if [ -f "$F2B_JAIL" ]; then write_f2b_jail "$NEW_PORT"; svc_restart fail2ban || true; fi
}

apply_lockdown() {
  title "Applying the lockdown"
  : >>"$LOG"
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  [ -z "$SSHD" ] || install_keys
  if [ "$FW" != none ]; then
    if setup_firewall; then FW_OK=yes; ok "Firewall ($FW) is on."
    else warn "Firewall setup failed (see $LOG)."; FW_RESULT="FAILED (see $LOG)"; fi
  elif [[ "$FIREWALL" =~ ^[Nn] ]]; then FW_RESULT="not touched (FIREWALL=no)"
  else FW_RESULT="skipped (not supported here)"; fi
  if setup_fail2ban; then F2B_RESULT="on: 5 failed logins = 1 hour ban"; ok "fail2ban is watching SSH."
  else F2B_RESULT="FAILED or skipped (see $LOG)"; warn "fail2ban could not be set up (see $LOG)."; fi
  configure_ssh || true
  finish_port_move || true
  fw_result
}
fw_result() {
  [ "$FW_OK" = yes ] || return 0
  local open="$OLD_PORT" extra=""
  if [ "$PORT_OK" = yes ]; then open="$NEW_PORT"; fi
  if [ ${#KEEP_OPEN[@]} -gt 0 ]; then extra=", ${KEEP_OPEN[*]}"; fi
  FW_RESULT="$FW on: incoming blocked except TCP $open$extra"
}

# ======================= report ==============================================
build_report() {
  local port="${OLD_PORT}" pw="still ON" cmd
  [ "$PORT_OK" = yes ] && port="$NEW_PORT"
  [ "$PW_OK" = yes ] && pw="OFF (SSH keys only)"
  cmd="ssh ${KEY_FILE_HINT}-p $port $LOGIN_USER@$SERVER_IP"
  line
  say "  PROTECT-YOURSELF REPORT  -  ${HOSTNAME:-server}  -  $(date '+%F %T %Z')"
  line
  printf '  %-18s %s\n' "System:"          "$OS_NAME"
  printf '  %-18s %s\n' "Auto updates:"    "$UPD_TOOL ($UPD_SCHEDULE)"
  printf '  %-18s %s\n' "Reboots:"         "$REBOOT_DESC"
  if [ "$LOCKDOWN" = yes ]; then
    printf '  %-18s %s\n' "Firewall:"      "$FW_RESULT"
    printf '  %-18s %s\n' "fail2ban:"      "$F2B_RESULT"
    if [ -n "$SSHD" ]; then
      printf '  %-18s %s\n' "SSH key:"       "$KEY_RESULT"
      printf '  %-18s %s\n' "Password login:" "$pw"
      printf '  %-18s %s\n' "SSH settings:"  "$SSH_RESULT"
      say ""
      if [ "$PORT_OK" = yes ]; then
        say "  >>> YOUR NEW SSH PORT IS:  $port   (it used to be $OLD_PORT) <<<"
      else
        say "  SSH port: $port (unchanged)"
      fi
      say "  Connect with:  $cmd"
      [ "$SOCKET_CHANGED" = yes ] && say "  (Ubuntu: switched SSH from ssh.socket to ssh.service so the new port sticks.)"
      [ -n "$CLOUD" ] && [ "$PORT_OK" = yes ] && say "  Cloud firewall: make sure TCP $port is open in your $CLOUD."
      say ""
      say "  !! KEEP THIS WINDOW OPEN. Test logging in from a NEW window first."
      say "  !! If you get locked out, use your provider's web console (see README)."
    fi
  else
    say ""
    say "  Lockdown was skipped. Run the command again any time to do it."
  fi
  say ""
  say "  Log: $LOG    Backups: $BACKUP_DIR"
  say "  This report is saved at $REPORT_FILE"
  line
}
print_report() {
  local r; r="$(build_report)"
  ( umask 077; printf '%s\n' "$r" >"$REPORT_FILE" ) || true
  printf '\n%s%s%s\n' "$B" "$r" "$N"
}

safety_check() {
  [ "$SAFETY_CHECK" != no ] && [ "$HAVE_TTY" = yes ] || return 0
  [ "$PORT_OK" = yes ] || [ "$PW_OK" = yes ] || return 0
  local port="$OLD_PORT" ans
  [ "$PORT_OK" = yes ] && port="$NEW_PORT"
  say ""
  say "${YEL}${B}LAST STEP: test the new login so you can't get locked out.${N}"
  say "  1. Open a NEW terminal window (leave this one open)."
  say "  2. Run:  ssh ${KEY_FILE_HINT}-p $port $LOGIN_USER@$SERVER_IP"
  say "  If it works, type y here. If it doesn't, type n and I'll undo the SSH changes."
  say "  (No answer in $((SAFETY_TIMEOUT / 60)) minutes = undo automatically.)"
  trap 'exec >>"$LOG" 2>&1; log "Connection lost during safety check; undoing SSH changes"; undo_ssh; exit 1' HUP
  ans=""
  read -r -t "$SAFETY_TIMEOUT" -p "Did the new login work? [y/n]: " ans </dev/tty || ans=""
  trap - HUP
  if yes_no "$ans"; then
    ok "Great - keeping the changes."
  else
    warn "Undoing SSH changes (port and password settings). Firewall and fail2ban stay on."
    undo_ssh
    if [ "$PORT_OK" = yes ]; then fw_close "$NEW_PORT"; fi
    PORT_OK=no; PW_OK=no; KEY_FILE_HINT=""; fw_result
    SSH_RESULT="UNDONE after a failed/missed login test - back to port $OLD_PORT, passwords as before"
    print_report
  fi
}

# ======================= main ================================================
LOCKDOWN=no
main() {
  # When piped (curl | sudo bash), stop commands from eating the script; questions use /dev/tty.
  [ -t 0 ] || exec </dev/null
  if (exec </dev/tty) 2>/dev/null; then HAVE_TTY=yes; fi
  [ "$(id -u)" -eq 0 ] || die "Please run with sudo:  curl -fsSL https://raw.githubusercontent.com/dieselbabyy/protect-yourself/main/protect-yourself.sh | sudo bash"
  [[ "$REBOOT_TIME" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || die "REBOOT_TIME must look like 04:00 (24-hour clock)."
  RB_H=$((10#${REBOOT_TIME%%:*})); RB_M=$((10#${REBOOT_TIME##*:}))
  touch "$LOG"; chmod 600 "$LOG"; log "protect-yourself started"

  detect_system
  line
  say "  ${B}Protect Yourself${N} - keeps this server updated and locked down"
  say "  Detected: $OS_NAME"
  line

  setup_updates

  if [ -z "$HARDEN" ] && [ "$HAVE_TTY" != yes ]; then
    say ""; say "No keyboard attached, so I stopped after updates. Run with HARDEN=yes to also lock down."
    print_report; return 0
  fi
  if [[ "$HARDEN" =~ ^[Nn] ]]; then print_report; return 0; fi

  plan_lockdown
  show_summary
  local answer="$HARDEN"
  if [ -z "$answer" ]; then answer="$(ask "Apply these changes? [y/N]: " N)"; fi
  if ! yes_no "$answer"; then
    say "OK, nothing else was changed."
    print_report; return 0
  fi
  LOCKDOWN=yes
  apply_lockdown
  print_report
  safety_check
  say ""; ok "All done. Stay safe!"
}

if [ "${PROTECT_YOURSELF_NO_MAIN:-}" != 1 ]; then main "$@"; fi
