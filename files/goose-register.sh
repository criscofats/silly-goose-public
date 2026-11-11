#!/bin/bash
# Boot-time registration for the goose troubleshooting node. Idempotent: it
# acts on the actual registration state, not on a marker file.
# Credentials arrive as systemd credentials; nothing is stored in the image.
set -euo pipefail

cred_dir="${CREDENTIALS_DIRECTORY:-}"
org_file="${cred_dir}/goose.org_id"
key_file="${cred_dir}/goose.activation_key"

if [[ -z "$cred_dir" || ! -r "$org_file" || ! -r "$key_file" ]]; then
    echo "goose-register: no registration credentials supplied, skipping."
    exit 0
fi

if subscription-manager identity >/dev/null 2>&1; then
    echo "goose-register: already registered with RHSM."
else
    subscription-manager register \
        --org "$(<"$org_file")" \
        --activationkey "$(<"$key_file")"
fi

# --register also enables the insights-client timer.
if [[ -e /etc/insights-client/.registered ]]; then
    echo "goose-register: already registered with Insights."
else
    insights-client --register
fi

echo "goose-register: registration complete."
