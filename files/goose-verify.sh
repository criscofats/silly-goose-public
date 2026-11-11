#!/bin/bash
# Verify goose-redhat is wired to the RHEL command-line assistant (CLA) backend:
#   goose (provider rhel_cla) -> goose-proxy (127.0.0.1:7080) -> Red Hat CLA backend
# Exit codes: 0 = verified end to end, 2 = config OK but system not registered
# (backend test skipped), 1 = failure.
set -uo pipefail

fail() { echo "FAIL: $*"; exit 1; }

rpm -q goose-redhat goose-proxy >/dev/null || fail "goose-redhat and/or goose-proxy are not installed"

# Run the same per-user setup a login shell does: it copies the Red Hat config
# and the rhel_cla custom provider into ~/.config/goose if they are missing.
# shellcheck source=/dev/null
source /etc/profile.d/goose-init.sh

cfg="${HOME}/.config/goose/config.yaml"
for f in "$cfg" "${HOME}/.config/goose/custom_providers/rhel_cla.json"; do
    if [[ -e "$f" && ! -r "$f" ]]; then
        fail "$f exists but is unreadable (check its SELinux label: ls -Z $f)"
    fi
done
grep -qx 'GOOSE_PROVIDER: rhel_cla' "$cfg" \
    || fail "$cfg does not select 'GOOSE_PROVIDER: rhel_cla'"
grep -qx 'GOOSE_MODEL: RHEL-command-line-assistant' "$cfg" \
    || fail "$cfg does not select 'GOOSE_MODEL: RHEL-command-line-assistant'"
[[ -f "${HOME}/.config/goose/custom_providers/rhel_cla.json" ]] \
    || fail "rhel_cla custom provider missing from ~/.config/goose/custom_providers"
systemctl is-active --quiet goose-proxy.socket \
    || fail "goose-proxy.socket is not listening on 127.0.0.1:7080"
echo "OK: goose config uses rhel_cla / RHEL-command-line-assistant via goose-proxy"

# The CLA backend authenticates with the system's RHSM identity.
if [[ ! -e /etc/pki/consumer/cert.pem ]]; then
    echo "SKIP: system is not registered with Red Hat; the CLA backend needs registration, so the live backend test was skipped"
    exit 2
fi

out=$(timeout 120 goose run --no-session -t "Reply with only the word OK" 2>&1) \
    || fail "backend request failed: $(tail -n 5 <<<"$out")"
grep -q 'rhel_cla RHEL-command-line-assistant' <<<"$out" \
    || fail "goose session did not start on rhel_cla / RHEL-command-line-assistant"
echo "OK: RHEL command-line assistant backend answered"
