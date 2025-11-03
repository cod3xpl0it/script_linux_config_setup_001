#!/usr/bin/env bash
set -euo pipefail

# Script to install and configure a fully isolated Firefox ESR sandbox
SANDBOX_USER="firefox_sandbox"
SANDBOX_HOME="/var/lib/firefox_sandbox"
LAUNCHER="/usr/local/bin/safe-firefox-esr"
APPARMOR_PROFILE="/etc/apparmor.d/usr.lib.firefox-esr.firefox-esr"
BACKUP_DIR="/etc/apparmor.d/backup-$(date +%Y%m%d%H%M%S)"
FIREFOX_BIN="/usr/lib/firefox-esr/firefox-esr"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
  fi
}

install_packages() {
  echo "Installing required packages..."
  apt-get update -y
  apt-get install -y apparmor apparmor-utils apparmor-profiles firejail
}

create_sandbox_user() {
  if id -u "$SANDBOX_USER" >/dev/null 2>&1; then
    echo "Sandbox user already exists."
  else
    echo "Creating sandbox user..."
    /sbin/useradd -m -d "$SANDBOX_HOME" -s /usr/sbin/nologin "$SANDBOX_USER"
    passwd -l "$SANDBOX_USER" >/dev/null 2>&1 || true
    chown root:root "$SANDBOX_HOME"
    chmod 0755 "$SANDBOX_HOME"
  fi
}

backup_existing_profile() {
  if [ -f "$APPARMOR_PROFILE" ]; then
    echo "Backing up existing AppArmor profile..."
    mkdir -p "$BACKUP_DIR"
    cp -a "$APPARMOR_PROFILE" "$BACKUP_DIR/"
  fi
}

write_apparmor_profile() {
  echo "Writing AppArmor profile..."
  cat > "$APPARMOR_PROFILE" <<'EOF'
#include <tunables/global>

profile /usr/lib/firefox-esr/firefox-esr flags=(attach_disconnected,mediate_deleted) {
  /usr/lib/firefox-esr/firefox-esr ix,
  /usr/lib/firefox-esr/** r,
  /usr/lib/x86_64-linux-gnu/** r,
  /lib/** r,
  /lib64/** r,
  /usr/lib/** r,
  /usr/share/** r,
  /usr/share/fonts/** r,
  /usr/share/icons/** r,
  /usr/share/glib-2.0/schemas/** r,
  /usr/share/ca-certificates/** r,
  /etc/ssl/** r,
  /etc/hosts r,
  /etc/resolv.conf r,
  include <abstractions/base>
  include <abstractions/nameservice>
  include <abstractions/fonts>
  include <abstractions/ssl_certs>
  include <abstractions/X>
  include <abstractions/wayland>

  network inet stream,
  network inet6 stream,
  network inet dgram,
  network inet6 dgram,

  deny /home/** rwkl,
  deny @{HOME}/** rwkl,
  deny /etc/** rwkl,
  deny /root/** rwkl,
  deny /var/** rwkl,
  deny /opt/** rwkl,
  deny /tmp/** rwkl,
  deny /dev/** rwkl,
  deny /proc/** rwkl,
  deny /sys/** rwkl,
  deny /run/** rwkl,
  deny /run/dbus/** rwkl,
  deny /run/user/** rwkl,

  deny /usr/bin/** x,
  deny /bin/** x,
  deny /sbin/** x,

  deny ptrace (trace,read,write),
  capability net_bind_service,
}
EOF
}

load_and_enforce_profile() {
  echo "Loading AppArmor profile..."
  /sbin/apparmor_parser -r "$APPARMOR_PROFILE"
  if command -v aa-enforce >/dev/null 2>&1; then
    /sbin/aa-enforce /usr/lib/firefox-esr/firefox-esr || true
  fi
}

write_launcher() {
  echo "Creating launcher $LAUNCHER ..."
  cat > "$LAUNCHER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Safe Firefox ESR launcher (no sudo required)
FIREFOX_BIN="/usr/lib/firefox-esr/firefox-esr"

# Create temporary isolated HOME directory
TMPHOME=$(mktemp -d /tmp/firefox_home.XXXXXX)
chmod 0700 "$TMPHOME"

# Run Firefox inside Firejail using temporary HOME
firejail --private="$TMPHOME" \
         --seccomp \
         --caps.drop=all \
         --private-dev \
         --quiet \
         -- "$FIREFOX_BIN" "$@"

# Remove temporary HOME
rm -rf "$TMPHOME"
echo "Temporary HOME removed."
EOF

  chmod +x "$LAUNCHER"
  echo "Launcher created. Run as normal user: $LAUNCHER"
}

create_desktop_shortcut() {
  echo "Creating desktop shortcut for all users..."
  DESKTOP_FILE="/usr/share/applications/safe-firefox-esr.desktop"

  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Name=Safe Firefox ESR
Comment=Open Firefox ESR in isolated sandbox
Exec=$LAUNCHER %u
Icon=firefox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

  chmod 644 "$DESKTOP_FILE"

  # Copy to Desktop folder of all users
  for user_home in /home/*; do
    if [ -d "$user_home/Desktop" ]; then
      cp "$DESKTOP_FILE" "$user_home/Desktop/"
      chown $(basename "$user_home"):$(basename "$user_home") "$user_home/Desktop/safe-firefox-esr.desktop"
    fi
  done
  echo "Desktop shortcut created for all users."
}

print_notes() {
  cat <<'EOF'

NOTES:

1) Run the launcher as your normal user (do NOT use sudo).
2) Firefox runs fully isolated — no access to /home or other files.
3) Temporary home directory is removed automatically after exit.
4) For better security, use Wayland instead of X11.
5) Passwords should be stored securely, not in plain text.
6) To restore the original AppArmor profile, see /etc/apparmor.d/backup-XXXX
7) To remove sandbox: sudo userdel -r firefox_sandbox
8) To remove launcher: sudo rm -f /usr/local/bin/safe-firefox-esr

EOF
}

# --- Run setup ---
require_root
install_packages
create_sandbox_user
backup_existing_profile
write_apparmor_profile
load_and_enforce_profile
write_launcher
create_desktop_shortcut
print_notes

echo "Setup complete. Run 'Safe Firefox ESR' from the desktop or '$LAUNCHER' as your normal user."
