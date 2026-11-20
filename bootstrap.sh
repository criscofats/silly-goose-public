#!/usr/bin/env bash
# bootstrap.sh - prepare a fresh Fedora / RHEL-family host to run this project.
#
#   1. Checks for (and offers to install) everything needed before Ansible can
#      take over: ansible-core, podman, openssh-clients, python3.
#   2. Checks the registry.redhat.io login and offers to log in.
#   3. Prompts for the local settings and credentials and writes two
#      git-ignored files: settings.yml (plain; loaded automatically by the
#      playbooks) and secrets.yml (credentials only, mode 0600, optionally
#      ansible-vault encrypted as a whole).
#   4. Prints (and optionally runs) the deploy command.
#
# The playbook itself installs the KVM packages (libvirt, virt-install,
# qemu-kvm) when deployment_mode is kvm, so they are not installed here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SCRIPT_DIR}/secrets.yml"
SETTINGS_FILE="${SCRIPT_DIR}/settings.yml"
MIN_ANSIBLE_CORE="2.14"
REGISTRY="registry.redhat.io"

ASSUME_YES=0
SKIP_SECRETS=0
SKIP_LOGIN=0
ALLOW_ROOT=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Prepare this host to run deploy-goose-server.yml.

Options:
  -y, --yes          Install missing packages without asking
      --no-secrets   Skip the settings.yml / secrets.yml questions
      --no-login     Skip the registry.redhat.io login check
      --allow-root   Allow running as root (not recommended; see README)
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --no-secrets) SKIP_SECRETS=1 ;;
        --no-login) SKIP_LOGIN=1 ;;
        --allow-root) ALLOW_ROOT=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# --------------------------------------------------------------- helpers
if [[ -t 1 ]]; then
    B=$'\033[1m'; BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; N=$'\033[0m'
else
    B=""; BLUE=""; GREEN=""; YELLOW=""; RED=""; N=""
fi
step() { printf '\n%s==>%s %s%s%s\n' "$BLUE" "$N" "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$N" "$*"; }
err()  { printf '  %s✗%s %s\n' "$RED" "$N" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ask_yn "question" default(y|n) -> returns 0 for yes
ask_yn() {
    local q="$1" def="${2:-n}" ans hint
    [[ "$def" == y ]] && hint="[Y/n]" || hint="[y/N]"
    read -r -p "  $q $hint " ans || ans=""
    ans="${ans:-$def}"
    [[ "$ans" =~ ^[Yy] ]]
}

# ask "prompt" "default" -> prints answer
ask() {
    local q="$1" def="${2:-}" ans
    if [[ -n "$def" ]]; then
        read -r -p "  $q [$def]: " ans || ans=""
    else
        read -r -p "  $q: " ans || ans=""
    fi
    printf '%s' "${ans:-$def}"
}

# ask_secret "prompt" -> prints answer (input hidden)
ask_secret() {
    local q="$1" ans
    read -r -s -p "  $q: " ans || ans=""
    printf '\n' >&2
    printf '%s' "$ans"
}

# ask_masked "prompt" -> prints answer, echoing '*' for each character typed.
# Backspace deletes, Ctrl-U clears, arrow/escape keys are ignored. When stdin
# is not a terminal (piped or scripted input) it falls back to hidden input.
ask_masked() {
    local q="$1" ans="" ch
    if [[ ! -t 0 ]]; then
        read -r -s ans || ans=""
        printf '%s' "$ans"
        return
    fi
    printf '  %s: ' "$q" >&2
    while IFS= read -r -s -n1 ch; do
        case "$ch" in
            "") break ;;                                   # Enter
            $'\x7f'|$'\b')                                 # Backspace / Ctrl-H
                if [[ -n "$ans" ]]; then ans="${ans%?}"; printf '\b \b' >&2; fi ;;
            $'\x15')                                       # Ctrl-U: clear the line
                while [[ -n "$ans" ]]; do ans="${ans%?}"; printf '\b \b' >&2; done ;;
            $'\e') read -r -s -n2 -t 0.1 _ || true ;;       # swallow arrow-key sequences
            *) ans+="$ch"; printf '*' >&2 ;;
        esac
    done
    printf '\n' >&2
    printf '%s' "$ans"
}

# YAML single-quoted scalar ('' escapes a quote). Inputs are single-line.
yq() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

# ------------------------------------------------------------ preflight
step "Checking this host"

if [[ $EUID -eq 0 && $ALLOW_ROOT -eq 0 ]]; then
    die "Run this as your normal user, not root. The playbook escalates with sudo itself, and the registry login and SSH key should belong to you. (Use --allow-root to override.)"
fi
SUDO="sudo"
[[ $EUID -eq 0 ]] && SUDO=""

[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; unsupported system."
# shellcheck source=/dev/null
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
case " $OS_ID $OS_LIKE " in
    *" fedora "*|*" rhel "*|*" centos "*) ok "Supported OS: ${PRETTY_NAME:-$OS_ID}" ;;
    *) die "Unsupported OS '${PRETTY_NAME:-$OS_ID}'. This project supports Fedora and RHEL-family hosts (dnf)." ;;
esac
command -v dnf >/dev/null 2>&1 || die "dnf not found."
IS_RHEL=0
[[ "$OS_ID" == "rhel" ]] && IS_RHEL=1

if [[ -n "$SUDO" ]] && ! command -v sudo >/dev/null 2>&1; then
    die "sudo is not installed. Install it as root (dnf install sudo) and add your user to the wheel group."
fi

# --------------------------------------------------------- dependencies
step "Checking dependencies"

declare -a MISSING=()
check_cmd() {   # check_cmd <command> <package> <why>
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 ($3)"
    else
        warn "$1 missing ($3) -> package $2"
        MISSING+=("$2")
    fi
}
check_cmd python3          python3          "runs Ansible"
check_cmd ansible-playbook ansible-core     "runs the playbooks"
check_cmd podman           podman           "registry login, image build"
check_cmd ssh              openssh-clients  "KVM verification/teardown over SSH"
check_cmd ssh-keygen       openssh-clients  "creates the KVM admin SSH key"

if command -v ansible-playbook >/dev/null 2>&1; then
    ver="$(ansible-playbook --version 2>/dev/null | sed -nE '1s/.*core ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')"
    if [[ -n "$ver" ]] && ! version_ge "$ver" "$MIN_ANSIBLE_CORE"; then
        warn "ansible-core $ver is older than $MIN_ANSIBLE_CORE -> will offer to upgrade"
        MISSING+=("ansible-core")
    elif [[ -n "$ver" ]]; then
        ok "ansible-core $ver (>= $MIN_ANSIBLE_CORE)"
    fi
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    mapfile -t MISSING < <(printf '%s\n' "${MISSING[@]}" | sort -u)
    echo
    echo "  Missing: ${MISSING[*]}"
    if [[ $ASSUME_YES -eq 1 ]] || ask_yn "Install them now with '${SUDO:+sudo }dnf install ${MISSING[*]}'?" y; then
        if ! $SUDO dnf install -y "${MISSING[@]}"; then
            if [[ $IS_RHEL -eq 1 ]]; then
                die "dnf failed. On RHEL these packages come from BaseOS/AppStream: make sure the host is registered (sudo subscription-manager register) and try again."
            fi
            die "dnf failed; install the packages above manually and re-run."
        fi
        ok "Installed: ${MISSING[*]}"
    else
        die "Cannot continue without: ${MISSING[*]}"
    fi
else
    ok "All dependencies present"
fi

if [[ -e /dev/kvm ]]; then
    ok "/dev/kvm present (KVM mode available)"
else
    warn "/dev/kvm not found: KVM mode won't work on this host (Podman mode will)"
fi

# --------------------------------------------------------- registry login
if [[ $SKIP_LOGIN -eq 0 ]]; then
    step "Checking ${REGISTRY} login"
    if login="$(podman login --get-login "$REGISTRY" 2>/dev/null)"; then
        ok "Logged in as ${login}"
    else
        warn "Not logged in to ${REGISTRY} (needed to pull the RHEL bootc images)."
        echo "    Use your Red Hat login or a registry service account (https://access.redhat.com/terms-based-registry/)."
        if ask_yn "Log in now?" y; then
            podman login "$REGISTRY" || warn "Login failed; run 'podman login ${REGISTRY}' before deploying."
        else
            warn "Run 'podman login ${REGISTRY}' before deploying."
        fi
    fi
fi

# ------------------------------------------------- settings.yml + secrets.yml
# settings.yml holds plain settings; secrets.yml holds ONLY credentials. Keep
# them apart: ansible-core 2.22+ registers every value of a vault-encrypted
# vars file as a secret and redacts that text everywhere in output, so a
# setting like deployment_mode: podman in an encrypted file shows as $REDACTED$.
ENCRYPTED=0
DEPLOY_MODE="podman"
is_vault() { grep -q 'ANSIBLE_VAULT' "$1" 2>/dev/null; }

if [[ $SKIP_SECRETS -eq 0 ]]; then
    step "Local settings (settings.yml) and credentials (secrets.yml)"
    write_it=1
    if [[ -e "$SETTINGS_FILE" || -e "$SECRETS_FILE" ]]; then
        [[ -e "$SETTINGS_FILE" ]] && warn "settings.yml already exists."
        if [[ -e "$SECRETS_FILE" ]]; then
            if is_vault "$SECRETS_FILE"; then
                warn "secrets.yml already exists (ansible-vault encrypted)."
                ENCRYPTED=1
            else
                warn "secrets.yml already exists."
            fi
            if [[ ! -e "$SETTINGS_FILE" ]]; then
                warn "No settings.yml: secrets.yml is probably the older combined format (settings and"
                warn "credentials in one file). If it is encrypted, Ansible redacts every value in it from"
                warn "output - e.g. 'podman' shows as \$REDACTED\$. Replace it to split it into two files."
            fi
        fi
        if ask_yn "Replace them? (existing files are kept as timestamped backups)" n; then
            stamp="$(date +%Y%m%d-%H%M%S)"
            for f in "$SETTINGS_FILE" "$SECRETS_FILE"; do
                if [[ -e "$f" ]]; then
                    cp -p "$f" "${f}.bak-${stamp}"
                    ok "Backed up $(basename "$f") to $(basename "$f").bak-${stamp}"
                fi
            done
            ENCRYPTED=0
        else
            write_it=0
            ok "Keeping the existing files"
        fi
    fi

    if [[ $write_it -eq 1 ]]; then
        echo "  Press Enter to accept a [default]. Nothing you type here is echoed or logged."
        echo

        # deployment mode
        while :; do
            DEPLOY_MODE="$(ask "Deployment mode (podman or kvm)" podman)"
            [[ "$DEPLOY_MODE" == podman || "$DEPLOY_MODE" == kvm ]] && break
            warn "Enter 'podman' or 'kvm'."
        done

        # registration credentials (also the default builder credentials)
        echo
        echo "  ${B}Red Hat registration${N} - the deployed node registers itself with Red Hat"
        echo "  and Insights on boot (required for the goose command-line assistant backend)."
        echo "  Create an activation key at https://console.redhat.com/insights/connector/activation-keys"
        ORG_ID=""; ACT_KEY=""
        while :; do
            ORG_ID="$(ask_masked "Organization ID (blank to skip automatic registration)")"
            [[ -z "$ORG_ID" || "$ORG_ID" =~ ^[0-9]+$ ]] && break
            warn "The organization ID is numeric."
        done
        if [[ -n "$ORG_ID" ]]; then
            while :; do
                ACT_KEY="$(ask_secret "Activation key name (hidden)")"
                [[ "$ACT_KEY" =~ ^[A-Za-z0-9._-]+$ ]] && break
                warn "Activation key names use letters, digits, '.', '_' and '-' only."
            done
            # Ansible redacts a vault-encrypted value wherever its full text appears
            # in output. A short key, or one contained in text this project prints,
            # would garble unrelated output (e.g. key 'goose' -> '$REDACTED$-proxy').
            clash=""
            for term in goose-admin-node goose-proxy goose-image-builder goose-rhel10-troubleshooter \
                        goose-verify goose-register podman kvm rhel redhat registry.redhat.io insights \
                        localhost admin root latest deploy teardown systemd quadlet bootc; do
                [[ "$term" == *"$ACT_KEY"* ]] && { clash="$term"; break; }
            done
            if [[ -n "$clash" || ${#ACT_KEY} -lt 8 ]]; then
                if [[ -n "$clash" ]]; then
                    warn "This activation key name is part of '$clash', which appears in normal output."
                else
                    warn "This activation key name is short (under 8 characters)."
                fi
                warn "If secrets.yml is encrypted, Ansible will show every occurrence of it as \$REDACTED\$."
                warn "A longer, specific key name (e.g. goose-demo-node-2026) avoids that. Continuing anyway."
            fi
        fi

        # build entitlement
        echo
        echo "  ${B}RHEL content for the image build${N}"
        echo "    1) Use my Red Hat account (registers a 'goose-image-builder' identity; no files to copy)"
        echo "    2) Use a folder of entitlement files copied from a registered RHEL system"
        echo "    3) This host is a registered RHEL system (nothing needed)"
        def_ent=1; [[ $IS_RHEL -eq 1 ]] && def_ent=3
        while :; do
            ENT="$(ask "Choose 1, 2 or 3" "$def_ent")"
            [[ "$ENT" =~ ^[123]$ ]] && break
        done
        BUILDER_USER=""; BUILDER_PASS=""; BUILDER_ORG=""; SECRETS_DIR=""
        case "$ENT" in
            1)
                if [[ -n "$ACT_KEY" ]]; then
                    ok "The builder will use the organization ID and activation key above."
                else
                    echo "  No activation key given, so the builder needs your Red Hat login."
                    BUILDER_USER="$(ask "Red Hat username" "")"
                    [[ -n "$BUILDER_USER" ]] || die "A username or an activation key is required for option 1."
                    while :; do
                        BUILDER_PASS="$(ask_secret "Red Hat password (hidden)")"
                        p2="$(ask_secret "Repeat password")"
                        [[ -n "$BUILDER_PASS" && "$BUILDER_PASS" == "$p2" ]] && break
                        warn "Passwords were empty or didn't match."
                    done
                    unset p2
                    BUILDER_ORG="$(ask_masked "Organization ID for the builder (only if your login belongs to several orgs)")"
                fi
                ;;
            2)
                SECRETS_DIR="$(ask "Path to the entitlement folder" /etc/goose/rhsm-secrets)"
                if $SUDO test -d "$SECRETS_DIR/etc-pki-entitlement" && $SUDO test -d "$SECRETS_DIR/rhsm" && $SUDO test -f "$SECRETS_DIR/redhat.repo"; then
                    ok "$SECRETS_DIR has the expected layout"
                else
                    warn "$SECRETS_DIR doesn't (yet) contain etc-pki-entitlement/, rhsm/ and redhat.repo - see README 'Building on a non-RHEL host'."
                fi
                ;;
            3)
                if [[ $IS_RHEL -eq 0 ]]; then
                    warn "This host is not RHEL; the playbook will stop and ask for an entitlement source."
                fi
                ;;
        esac

        # KVM admin SSH key
        if [[ "$DEPLOY_MODE" == kvm ]]; then
            echo
            if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
                ok "SSH key found: ~/.ssh/id_ed25519.pub (used for the VM's 'goose' admin user)"
            elif ask_yn "No ~/.ssh/id_ed25519.pub - create one now for the VM's admin user?" y; then
                mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
                ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -C "${USER:-goose}@goose-admin-node"
            else
                warn "KVM deploys need an SSH public key (admin_ssh_pubkey_file)."
            fi
        fi

        # settings.yml: plain settings, loaded automatically by the playbooks
        tmp="$(mktemp "${SCRIPT_DIR}/.settings.yml.XXXXXX")"
        chmod 644 "$tmp"
        {
            echo "---"
            echo "# Local, machine-specific settings (no credentials). Ignored by git."
            echo "# Generated by bootstrap.sh on $(date -Iseconds). The playbooks load this file"
            echo "# automatically; -e on the command line overrides it."
            echo "deployment_mode: $(yq "$DEPLOY_MODE")"
            case "$ENT" in
                1) echo "rhsm_builder_register: true" ;;
                2) echo "rhsm_secrets_dir: $(yq "$SECRETS_DIR")" ;;
            esac
        } > "$tmp"
        mv -f "$tmp" "$SETTINGS_FILE"
        ok "Wrote settings.yml (plain text, ignored by git)"

        # secrets.yml: credentials only (if any were entered)
        if [[ -n "$ORG_ID$ACT_KEY$BUILDER_USER$BUILDER_PASS$BUILDER_ORG" ]]; then
            tmp="$(mktemp "${SCRIPT_DIR}/.secrets.yml.XXXXXX")"
            chmod 600 "$tmp"
            {
                echo "---"
                echo "# Credentials only. Ignored by git - never commit. Generated by bootstrap.sh"
                echo "# on $(date -Iseconds). Use with: -e @secrets.yml (add --ask-vault-pass if encrypted)."
                echo "# Keep non-secret settings in settings.yml: Ansible redacts every value of an"
                echo "# encrypted vars file wherever that text appears in output."
                echo "insights_org_id: $(yq "$ORG_ID")"
                echo "insights_activation_key: $(yq "$ACT_KEY")"
                if [[ -n "$BUILDER_USER" ]]; then
                    echo "rhsm_builder_username: $(yq "$BUILDER_USER")"
                    echo "rhsm_builder_password: $(yq "$BUILDER_PASS")"
                    echo "rhsm_builder_org_id: $(yq "$BUILDER_ORG")"
                fi
            } > "$tmp"
            mv -f "$tmp" "$SECRETS_FILE"
            ok "Wrote secrets.yml (mode 0600, ignored by git)"

            if ask_yn "Encrypt secrets.yml with ansible-vault? (recommended; you'll choose a vault password)" y; then
                if ansible-vault encrypt "$SECRETS_FILE"; then
                    ENCRYPTED=1
                    ok "secrets.yml encrypted - edit it later with: ansible-vault edit secrets.yml"
                else
                    warn "Encryption failed; secrets.yml is still plain text (mode 0600)."
                fi
            fi
        else
            rm -f "$SECRETS_FILE"
            ok "No credentials entered, so no secrets.yml (automatic registration stays off)"
        fi
        unset BUILDER_PASS ACT_KEY
    fi
fi

# ---------------------------------------------------------------- summary
step "Ready"
cmd=(ansible-playbook deploy-goose-server.yml -K)
if [[ -e "$SECRETS_FILE" ]]; then
    cmd+=(-e @secrets.yml)
    [[ $ENCRYPTED -eq 1 ]] && cmd+=(--ask-vault-pass)
fi
td=(ansible-playbook teardown-goose-server.yml -K "${cmd[@]:3}")
echo "  Deploy with:"
echo "    cd ${SCRIPT_DIR} && ${cmd[*]}"
echo "  Tear down with:"
echo "    cd ${SCRIPT_DIR} && ${td[*]}"
echo
if ask_yn "Run the deploy now?" n; then
    cd "$SCRIPT_DIR"
    exec "${cmd[@]}"
fi
