#!/bin/bash
# Runs inside a short-lived rhel-bootc container on the build host. Registers
# (once) a persistent "image builder" identity with Red Hat using the user's
# credentials, refreshes its content certificates, verifies the entitlement
# provides goose-redhat, and exports the result in the same layout RHEL hosts
# give podman builds at /run/secrets:
#   /out/etc-pki-entitlement/  /out/rhsm/  /out/redhat.repo
# Identity state (/etc/pki/consumer, /etc/pki/entitlement, /var/lib/rhsm) is
# bind-mounted from the host, so re-runs reuse the same registered system.
set -euo pipefail

creds=/run/goose-builder-creds
out=/out

opt() { if [[ -s "${creds}/$1" ]]; then cat "${creds}/$1"; fi; }

# Generate /etc/yum.repos.d/redhat.repo even if the image defaults to
# container-style manage_repos=0.
subscription-manager config --rhsm.manage_repos=1

if subscription-manager identity >/dev/null 2>&1; then
    echo "builder: reusing existing registration"
else
    name="$(opt system_name)"
    org="$(opt org_id)"
    key="$(opt activation_key)"
    user="$(opt username)"
    if [[ -n "$key" ]]; then
        subscription-manager register --name "$name" --org "$org" --activationkey "$key"
    elif [[ -n "$user" ]]; then
        args=(--name "$name" --username "$user" --password "$(opt password)")
        if [[ -n "$org" ]]; then args+=(--org "$org"); fi
        subscription-manager register "${args[@]}"
    else
        echo "builder: no credentials supplied and not registered" >&2
        exit 1
    fi
    echo "builder: registered new build identity '$name'"
fi

subscription-manager refresh
subscription-manager repos --list-enabled >/dev/null

test -s /etc/yum.repos.d/redhat.repo \
    || { echo "builder: redhat.repo was not generated" >&2; exit 1; }
compgen -G "/etc/pki/entitlement/*.pem" >/dev/null \
    || { echo "builder: no entitlement certificates were issued" >&2; exit 1; }

repo="rhel-10-for-$(arch)-extensions-rpms"
dnf -q --disablerepo='*' --enablerepo="$repo" list goose-redhat >/dev/null \
    || { echo "builder: this account's entitlement does not provide goose-redhat from $repo" >&2; exit 1; }

# Export without SELinux labels (they belong to this container's MCS pair).
rm -rf "${out:?}/etc-pki-entitlement" "${out:?}/rhsm" "${out:?}/redhat.repo"
mkdir -p "${out}/etc-pki-entitlement" "${out}/rhsm"
cp -a --no-preserve=context /etc/pki/entitlement/. "${out}/etc-pki-entitlement/"
cp -a --no-preserve=context /etc/rhsm/. "${out}/rhsm/"
cp -a --no-preserve=context /etc/yum.repos.d/redhat.repo "${out}/redhat.repo"
echo "builder: entitlement exported (verified access to $repo)"
