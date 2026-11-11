#!/bin/bash
# First-boot registration for the goose troubleshooting node.
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
insights-client --register

mkdir -p /var/lib/goose-register
touch /var/lib/goose-register/done
echo "goose-register: registration complete."
