#!/usr/bin/env bash
# Debian 12/13 bootstrap. Run as root; does not require cloud-init.
# Paste ONLY your PUBLIC OpenSSH key here, or use --key-file.
ADMIN_PUBLIC_KEY=''

set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

usage() {
    cat <<'EOF'
Usage: bash server-base.sh [options]
  --key-file PATH          Public keys in OpenSSH authorized_keys format
  --admin-user NAME        Default: ckAdmin
  --timezone ZONE          Default: Europe/Berlin
  --upgrade                Run apt-get upgrade before setup (no autoremove)
  --unattended             Skip human login tests; requires recovery console
  --help                   Show help

Key source: --key-file, ADMIN_PUBLIC_KEY above, or ckAdmin.pub beside script.
Only plain RSA (>=2048 bit), Ed25519 and ECDSA public keys are accepted.
Private keys and authorized_keys options are not accepted as input.
Existing authorized_keys entries are retained.
The admin receives unrestricted passwordless sudo. No private key is needed.
SSH password/keyboard-interactive authentication is disabled for ALL users.
Root SSH login is disabled; local root/rescue access remains unchanged.
No firewall, swap, Docker, web server or automatic upgrade policy is installed.
EOF
}

log() { printf '\n[server-base] %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

validate_keys() {
    local input=$1 output=$2 line kind blob comment bits
    : > "$output"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*# ]] && continue
        read -r kind blob comment <<< "$line"
        case "$kind" in
            ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
            *) printf 'Unsupported key format; use an OpenSSH public key.\n' >&2; return 1 ;;
        esac
        [[ -n ${blob:-} ]] || return 1
        printf '%s %s\n' "$kind" "$blob" > "$output.check"
        if ! bits=$(ssh-keygen -lf "$output.check" -E sha256); then
            rm -f -- "$output.check"
            return 1
        fi
        if [[ $kind == ssh-rsa && ${bits%% *} -lt 2048 ]]; then
            printf 'RSA keys shorter than 2048 bits are rejected.\n' >&2
            rm -f -- "$output.check"
            return 1
        fi
        # Store canonical key material, without potentially identifying comments.
        if ! grep -Fqx -- "$kind $blob" "$output"; then
            printf '%s %s\n' "$kind" "$blob" >> "$output"
        fi
    done < "$input"
    rm -f -- "$output.check"
    [[ -s $output ]]
}

check_effective() {
    local config=$1 user=$2 addr=$3 result
    result=$(/usr/sbin/sshd -T -f "$config" \
        -C "user=$user,host=bootstrap-check,addr=$addr") || return 1
    local expected
    for expected in 'usepam yes' 'pubkeyauthentication yes' 'passwordauthentication no' \
        'kbdinteractiveauthentication no' 'authenticationmethods publickey'; do
        grep -Fqx "$expected" <<< "$result" || {
            printf 'Unexpected SSH setting for %s: %s\n' "$user" "$expected" >&2
            return 1
        }
    done
    if [[ $user == root ]]; then
        grep -Fqx 'permitrootlogin no' <<< "$result" || return 1
    else
        grep -Fqx 'authorizedkeysfile .ssh/authorized_keys' <<< "$result" || return 1
    fi
}

main() {
    local admin=ckAdmin timezone=Europe/Berlin key_file='' upgrade=no unattended=no
    while (($#)); do
        case "$1" in
            --help|-h) usage; return 0 ;;
            --key-file|--admin-user|--timezone)
                (($# >= 2)) || die "Missing value for $1"
                case "$1" in
                    --key-file) key_file=$2 ;;
                    --admin-user) admin=$2 ;;
                    --timezone) timezone=$2 ;;
                esac
                shift 2 ;;
            --upgrade) upgrade=yes; shift ;;
            --unattended) unattended=yes; shift ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ $admin =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,30}$ && $admin != root ]] || die 'Invalid admin username'
    ((EUID == 0)) || die 'Run this script as root'
    [[ -f /etc/os-release ]] || die 'Missing /etc/os-release'
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ $ID == debian && $VERSION_ID =~ ^(12|13)$ ]] || die 'Only Debian 12 and 13 are supported'
    [[ -d /run/systemd/system ]] || die 'A running systemd installation is required'
    [[ $timezone != /* && $timezone != *..* && -f /usr/share/zoneinfo/$timezone ]] || die 'Invalid or unavailable timezone'
    if [[ $unattended == no ]]; then
        [[ -t 0 && -t 1 ]] || die 'Interactive terminal required; otherwise use --unattended explicitly'
    fi

    command -v flock >/dev/null || die 'flock (util-linux) is required'
    exec 9>/run/lock/server-base.lock
    flock -n 9 || die 'Another server-base instance is running'

    WORK=$(mktemp -d /root/.server-base.XXXXXXXX)
    SSH_CHANGED=no
    trap cleanup EXIT
    trap 'printf "Failure at line %s.\n" "$LINENO" >&2' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    if [[ -n $key_file ]]; then
        [[ -f $key_file && -r $key_file ]] || die 'Public key file is not readable'
        cp -- "$key_file" "$WORK/input.pub"
    elif [[ -n $ADMIN_PUBLIC_KEY ]]; then
        printf '%s\n' "$ADMIN_PUBLIC_KEY" > "$WORK/input.pub"
    else
        key_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ckAdmin.pub"
        [[ -f $key_file ]] || die 'Supply --key-file or configure ADMIN_PUBLIC_KEY'
        cp -- "$key_file" "$WORK/input.pub"
    fi
    # Reject bad key material before installing or changing packages.
    command -v ssh-keygen >/dev/null || die 'ssh-keygen (openssh-client) is required'
    validate_keys "$WORK/input.pub" "$WORK/keys.pub" || die 'No valid public key supplied'
    log 'Public key fingerprints:'
    ssh-keygen -lf "$WORK/keys.pub" -E sha256

    log 'Installing base packages'
    apt-get update
    if [[ $upgrade == yes ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        sudo openssh-server ca-certificates curl cron mc htop tzdata
    timedatectl set-timezone "$timezone"
    systemctl is-active --quiet ssh.service || die 'ssh.service must already be running'
    /usr/sbin/sshd -t
    visudo -c

    if ! getent passwd "$admin" >/dev/null; then
        useradd --create-home --user-group --shell /bin/bash "$admin"
    fi
    local uid group home shell
    IFS=: read -r _ _ uid _ _ home shell < <(getent passwd "$admin")
    ((uid >= 1000 && uid < 65534)) || die 'Refusing to modify a system account'
    [[ $home == /home/* && -d $home && ! -L $home ]] || die 'Expected a regular home directory under /home'
    [[ $shell == /bin/bash ]] || die 'Existing account must have /bin/bash; inspect it manually'
    group=$(id -gn "$admin")
    [[ ! -L $home/.ssh && ! -L $home/.ssh/authorized_keys ]] || die 'Refusing symlinked SSH paths'
    [[ ! -e $home/.ssh/authorized_keys || -f $home/.ssh/authorized_keys ]] || die 'authorized_keys must be a regular file'
    chown "$admin:$group" "$home"
    chmod go-w "$home"
    install -d -m 0700 -o "$admin" -g "$group" "$home/.ssh"
    local auth="$home/.ssh/authorized_keys" kind blob
    if [[ -f $auth ]]; then
        cp -a -- "$auth" "$WORK/authorized_keys.before"
        awk '1' "$auth" > "$WORK/authorized_keys.new"
    else
        : > "$WORK/authorized_keys.new"
    fi
    while read -r kind blob; do
        # Compare key blobs also against entries with authorized_keys options.
        if ! awk -v key="$blob" '{for(i=1;i<=NF;i++) if($i==key) found=1} END {exit !found}' "$WORK/authorized_keys.new"; then
            printf '%s %s\n' "$kind" "$blob" >> "$WORK/authorized_keys.new"
        fi
    done < "$WORK/keys.pub"
    install -m 0600 -o "$admin" -g "$group" "$WORK/authorized_keys.new" "$auth"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$admin" > "$WORK/sudoers"
    visudo -cf "$WORK/sudoers"
    local sudo_file="/etc/sudoers.d/90-server-base-$admin"
    [[ ! -L $sudo_file ]] || die 'Refusing symlinked sudoers file'
    if [[ -e $sudo_file ]]; then cp -a -- "$sudo_file" "$WORK/sudoers.before"; fi
    install -m 0440 -o root -g root "$WORK/sudoers" "$sudo_file"
    if ! visudo -c || ! sudo -n -u "$admin" -- sudo -n true; then
        if [[ -f $WORK/sudoers.before ]]; then cp -a -- "$WORK/sudoers.before" "$sudo_file"; else rm -f -- "$sudo_file"; fi
        die 'sudo configuration failed validation'
    fi

    if [[ $unattended == no ]]; then
        log "Open a SECOND PuTTY session as $admin using your private key."
        printf 'In that session run: sudo -n id -u  (must print 0)\n'
        local answer
        read -r -p 'Only after successful key login and sudo test, type TESTED: ' answer
        [[ $answer == TESTED ]] || die 'Stopped; SSH authentication settings are unchanged'
    fi

    log 'Preparing SSH key-only login and disabling root SSH'
    SSH_FILE=/etc/ssh/sshd_config.d/00-server-base.conf
    [[ ! -L $SSH_FILE ]] || die 'Refusing symlinked SSH configuration'
    install -d -m 0755 /etc/ssh/sshd_config.d
    SSH_EXISTED=no
    if [[ -e $SSH_FILE ]]; then
        [[ -f $SSH_FILE ]] || die 'SSH configuration must be a regular file'
        cp -a -- "$SSH_FILE" "$WORK/ssh.before"
        SSH_EXISTED=yes
    fi
    cat > "$WORK/ssh.new" <<'EOF'
# Managed by server-base.sh. Root console access is not changed.
PermitRootLogin no
UsePAM yes
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
AuthorizedKeysFile .ssh/authorized_keys
EOF
    SSH_CHANGED=yes
    install -m 0600 -o root -g root "$WORK/ssh.new" "$SSH_FILE"
    /usr/sbin/sshd -t
    local addr=${SSH_CONNECTION:-}
    addr=${addr%% *}
    addr=${addr:-127.0.0.1}
    # Check both the current client address and loopback; arbitrary Match rules
    # for other addresses still require operator review.
    local check_addr
    for check_addr in "$addr" 127.0.0.1 ::1; do
        check_effective /etc/ssh/sshd_config root "$check_addr" || die 'Conflicting SSH rules for root'
        check_effective /etc/ssh/sshd_config "$admin" "$check_addr" || die 'Conflicting SSH rules for admin'
    done
    systemctl reload ssh.service
    systemctl is-active --quiet ssh.service
    if [[ $unattended == no ]]; then
        log "Open a NEW PuTTY session as $admin and repeat: sudo -n id -u"
        read -r -p 'After successful login under the NEW policy, type CONFIRM: ' answer
        [[ $answer == CONFIRM ]] || die 'Not confirmed; restoring previous SSH settings'
    fi
    SSH_CHANGED=no
    log "Complete: $admin has key login and passwordless sudo; root SSH is disabled."
    printf 'Backup directory: %s\nKeep the current session open until a fresh login works.\n' "$WORK"
}

cleanup() {
    local result=$?
    trap - EXIT ERR INT TERM HUP
    if [[ ${SSH_CHANGED:-no} == yes ]]; then
        printf '\nRestoring SSH configuration after failure or missing confirmation.\n' >&2
        if [[ $SSH_EXISTED == yes ]]; then
            cp -a -- "$WORK/ssh.before" "$SSH_FILE"
        else
            rm -f -- "$SSH_FILE"
        fi
        if /usr/sbin/sshd -t; then
            systemctl reload ssh.service || printf 'SSH reload failed; use the recovery console.\n' >&2
        else
            printf 'SSH config still invalid; use the recovery console.\n' >&2
        fi
    fi
    if [[ -n ${WORK:-} ]]; then
        rm -f -- "$WORK/input.pub" "$WORK/keys.pub" "$WORK/keys.pub.check"
        printf 'Backups/diagnostic files retained in %s\n' "$WORK" >&2
    fi
    exit "$result"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
