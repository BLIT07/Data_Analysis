#!/bin/bash
# =============================================================================
# Alma Linux Lab VM - VHDX Cleanup Script
# Cert IV Cyber Security - Linux Log Analysis Lab
#
# Run this as the FINAL step before shutting down and archiving the VHDX.
# This script clears all logs, histories, temp files and resets the journal
# so students start from a clean baseline.
#
# Usage: sudo bash cleanup_vhdx.sh
# =============================================================================

set -e

# Require root
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo bash cleanup_vhdx.sh)"
  exit 1
fi

echo ""
echo "============================================"
echo "  Alma Linux Lab VM - VHDX Cleanup"
echo "============================================"
echo ""

# -----------------------------------------------------------------------------
# 1. Bash histories - all users
# -----------------------------------------------------------------------------
echo "[1/8] Clearing bash histories..."

# Root
> /root/.bash_history
history -c 2>/dev/null || true

# All home directories
for HIST in /home/*/.bash_history; do
  > "$HIST" 2>/dev/null && echo "      Cleared: $HIST" || true
done

# -----------------------------------------------------------------------------
# 2. Journal logs
# -----------------------------------------------------------------------------
echo "[2/8] Resetting systemd journal..."

# Vacuum everything - leaves a clean empty journal
journalctl --rotate
journalctl --vacuum-time=1s

# -----------------------------------------------------------------------------
# 3. Auth and system logs
# -----------------------------------------------------------------------------
echo "[3/8] Clearing system log files..."

# Standard log files
for LOG in \
  /var/log/messages \
  /var/log/secure \
  /var/log/cron \
  /var/log/maillog \
  /var/log/boot.log \
  /var/log/wtmp \
  /var/log/btmp \
  /var/log/lastlog \
  /var/log/tallylog; do
  if [[ -f "$LOG" ]]; then
    > "$LOG" 2>/dev/null && echo "      Cleared: $LOG" || true
  fi
done

# Rotated logs
find /var/log -name "*.gz" -delete 2>/dev/null || true
find /var/log -name "*-[0-9]*" -delete 2>/dev/null || true
find /var/log -name "*.1" -delete 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. Audit logs
# -----------------------------------------------------------------------------
echo "[4/8] Clearing audit logs..."

# Rotate and clear the audit log
if systemctl is-active auditd &>/dev/null; then
  service auditd rotate
  > /var/log/audit/audit.log
  echo "      Audit log cleared and rotated"
else
  > /var/log/audit/audit.log 2>/dev/null || true
  echo "      Audit log cleared (auditd not running)"
fi

# Clear any rotated audit logs
find /var/log/audit -name "audit.log.*" -delete 2>/dev/null || true

# -----------------------------------------------------------------------------
# 5. Temp files
# -----------------------------------------------------------------------------
echo "[5/8] Clearing temp files..."

# /tmp - preserve directory structure but remove files
find /tmp -mindepth 1 -delete 2>/dev/null || true

# /var/tmp
find /var/tmp -mindepth 1 -not -name "." -delete 2>/dev/null || true

# -----------------------------------------------------------------------------
# 6. SSH known_hosts and host keys (regenerate on first boot)
# -----------------------------------------------------------------------------
echo "[6/8] Clearing SSH known_hosts..."

for KH in /root/.ssh/known_hosts /home/*/.ssh/known_hosts; do
  if [[ -f "$KH" ]]; then
    > "$KH" 2>/dev/null && echo "      Cleared: $KH" || true
  fi
done

# Note: We deliberately DO NOT remove /etc/ssh/ssh_host_* keys
# Removing them causes sshd to fail on boot unless configured to regenerate
# If you want fresh host keys, uncomment the lines below and ensure
# ssh-keygen runs at first boot via a systemd unit or rc.local:
# rm -f /etc/ssh/ssh_host_*
# echo "      SSH host keys removed - will regenerate on first boot"

# -----------------------------------------------------------------------------
# 7. DNF/package manager cache
# -----------------------------------------------------------------------------
echo "[7/8] Clearing package manager cache..."
dnf clean all &>/dev/null || true

# -----------------------------------------------------------------------------
# 8. Miscellaneous
# -----------------------------------------------------------------------------
echo "[8/8] Final cleanup..."

# Clear loginuid remnants
> /var/log/faillog 2>/dev/null || true

# Reset faillock counters for lab users
for USER in student jsmith labadmin; do
  faillock --user "$USER" --reset 2>/dev/null || true
done

# Clear any stale lock files
find /var/lock -mindepth 1 -not -name "." -delete 2>/dev/null || true

# Truncate shell history for current session
history -c
unset HISTFILE

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Cleanup complete."
echo ""
echo "  Next steps:"
echo "  1. Verify lab users and CRM files are intact:"
echo "     id jsmith && id labadmin && ls /var/company/crm/"
echo "  2. Verify auditd rule is still active:"
echo "     sudo auditctl -l"
echo "  3. Shut down the VM:"
echo "     sudo shutdown -h now"
echo "  4. Archive the VHDX from Hyper-V Manager"
echo "============================================"
echo ""
