# RHEL 10 Image Mode Server with Goose-RedHat

This project contains an Ansible playbook that builds and deploys a Red Hat Enterprise Linux (RHEL) 10 Image Mode (`bootc`) server. The server runs `goose-redhat`, an agentic AI CLI that uses Red Hat Knowledgebase (KB) content to troubleshoot issues across your fleet, and integrates with Red Hat Insights.

## Features

* **Image Mode OS (`bootc`):** Builds a RHEL 10 OS image with standard OCI tooling (Podman), validated with `bootc container lint`.
* **Two deployment targets:**
  * **Podman:** runs the image as a systemd container managed by a [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) unit, so it starts on boot.
  * **KVM:** converts the image to a `qcow2` disk with `bootc-image-builder` and boots it with `virt-install`.
* **Goose-RedHat:** installs `goose-redhat` from the RHEL 10 extensions repository.
* **Optional automatic registration:** registers with Red Hat Subscription Management and Insights on first boot using an activation key. Credentials are passed in at runtime and never baked into the image.
* **Safe to re-run:** dependencies are installed only for the selected mode. Disks and containers are rebuilt only when the image actually changes. An existing VM is never overwritten unless you ask for it.

## Repository Layout

```
deploy-goose-server.yml         # build and deploy
teardown-goose-server.yml       # remove everything deploy created
vars/goose.yml                  # shared settings for both playbooks
secrets.example.yml             # template for local secrets.yml (git-ignored)
templates/Containerfile.j2      # bootc image definition
templates/config.toml.j2        # bootc-image-builder config (KVM admin user, disk size)
templates/goose-node.container.j2  # Quadlet unit (Podman mode)
files/goose-register.{sh,service}  # first-boot RHSM + Insights registration
```

## Prerequisites

The playbook installs everything else for you (`podman`, plus `libvirt`, `virt-install` and `qemu-kvm` in KVM mode) and starts the libvirt daemons and network. You need to provide:

1. **Ansible:** `sudo dnf install ansible-core`
2. **Registry login:** log in to `registry.redhat.io` as your normal user or as root:
   ```bash
   podman login registry.redhat.io
   ```
   The playbook runs Podman as root. It uses root's own login if there is one. Otherwise it falls back to your user's auth files (`$XDG_RUNTIME_DIR/containers/auth.json`, `~/.config/containers/auth.json`, `~/.docker/config.json`) and passes the one that works to every Podman command through `REGISTRY_AUTH_FILE`. To use a specific file, set `registry_authfile`.
3. **RHEL content entitlement for the image build:** the build has to install packages from RHEL repositories.
   * **Registered RHEL host:** nothing to do. Podman passes the host's entitlement into the build automatically.
   * **Any other host (Fedora, etc.):** see [Building on a non-RHEL host](#building-on-a-non-rhel-host).
4. **SSH key (KVM mode only):** by default the playbook reads `~/.ssh/id_ed25519.pub` and adds it for the `goose` admin user. Override this with `admin_ssh_pubkey_file` or `admin_ssh_pubkey`.

### Building on a non-RHEL host

On a registered RHEL host, Podman mounts `/usr/share/rhel/secrets` at `/run/secrets` inside every build, and that is how `dnf` gets access to RHEL repositories. Other distributions don't do this, so you have to supply an equivalent directory yourself and set `rhsm_secrets_dir` to point at it.

The directory layout:

```
rhsm-secrets/
├── etc-pki-entitlement/   # *.pem entitlement certs  (from /etc/pki/entitlement)
├── rhsm/                  # rhsm.conf and ca/        (from /etc/rhsm)
└── redhat.repo            # repo definitions         (from /etc/yum.repos.d/redhat.repo)
```

The simplest source is a registered RHEL 10 system with the extensions repository available:

```bash
# On the registered RHEL system
sudo tar -czf rhsm-secrets.tgz \
  --transform 's,^etc/pki/entitlement,etc-pki-entitlement,;s,^etc/rhsm,rhsm,;s,^etc/yum.repos.d/,,' \
  -C / etc/pki/entitlement etc/rhsm etc/yum.repos.d/redhat.repo

# On the build host
sudo mkdir -p /etc/goose/rhsm-secrets
sudo tar -xzf rhsm-secrets.tgz -C /etc/goose/rhsm-secrets
sudo chmod -R go-rwx /etc/goose/rhsm-secrets
```

Copy real files rather than symlinks, because the directory is bind-mounted into the build container. Entitlement certificates expire, so refresh them if the build starts failing with 403 errors from the CDN.

## Configuration

Set variables in `vars/goose.yml`, or pass them with `-e`. Both the deploy and teardown playbooks load this file, so they always agree on names and paths. If you override `vm_name`, `image_name`, `build_dir` and so on with `-e` when deploying, pass the same overrides to teardown.

| Variable | Default | Purpose |
|---|---|---|
| `deployment_mode` | `podman` | `podman` or `kvm` |
| `vm_name` | `goose-admin-node` | VM name, or container/service name |
| `image_name` / `image_tag` | `goose-rhel10-troubleshooter` / `latest` | Local image name |
| `image_registry` | `""` | Registry repo to push to, e.g. `quay.io/myorg/goose-rhel10`. Needed for `bootc upgrade` |
| `extra_packages` | `[]` | Extra RPMs to add to the image, e.g. `[tcpdump, sysstat]` |
| `build_no_cache` | `false` | Rebuild every layer so newer RPMs are picked up |
| `rhsm_secrets_dir` | `""` | Entitlement directory for non-RHEL build hosts |
| `build_dir` | `/opt/goose-image-build` | Build context and bootc-image-builder output |
| `registry_authfile` | `""` | Registry auth file to use (empty = auto-detect) |
| `vm_memory` / `vm_vcpus` | `4096` / `2` | VM sizing |
| `vm_disk_size` | `20 GiB` | Minimum root filesystem size |
| `vm_os_variant` | `rhel10.0` | osinfo short ID |
| `vm_network` | `default` | libvirt network |
| `vm_recreate` | `false` | Destroy and rebuild an existing VM |
| `admin_user` | `goose` | KVM admin user (member of `wheel`, SSH key login only) |
| `admin_ssh_pubkey_file` | `~/.ssh/id_ed25519.pub` | Public key for `admin_user` |
| `admin_sudo_nopasswd` | `true` | Let `wheel` run sudo without a password (the admin user has no password) |
| `podman_privileged` | `false` | Run the container with `--privileged` |
| `insights_org_id` / `insights_activation_key` | `""` | Enable first-boot registration (set both) |

## Execution

```bash
# Podman mode (default)
ansible-playbook deploy-goose-server.yml -K

# KVM mode on a Fedora host
ansible-playbook deploy-goose-server.yml -K \
  -e deployment_mode=kvm \
  -e rhsm_secrets_dir=/etc/goose/rhsm-secrets

# Using your local settings/credentials file (see below)
ansible-playbook deploy-goose-server.yml -K -e @secrets.yml
```

### Local settings and credentials (`secrets.yml`)

Keep machine-specific settings and registration credentials in `secrets.yml`. It's listed in `.gitignore`, so it is **never committed**. Never put real credentials in `vars/goose.yml`.

```bash
cp secrets.example.yml secrets.yml && chmod 600 secrets.yml
$EDITOR secrets.yml
```

```yaml
rhsm_secrets_dir: "/etc/goose/rhsm-secrets"   # only needed on non-RHEL build hosts
insights_org_id: "1234567"
insights_activation_key: "goose-node-key"
```

To keep the file encrypted at rest, run `ansible-vault encrypt secrets.yml`, then add `--ask-vault-pass` to each run.

`-K` prompts for your sudo password. The play escalates to root to build images, write to `/etc` and manage libvirt.

### What the playbook does

1. **Pre-flight checks:** validates variables, installs the dependencies for the selected mode, confirms root's registry login, and checks for a RHEL entitlement (host subscription or `rhsm_secrets_dir`). In KVM mode it also starts `virtqemud`, `virtnetworkd` and `virtstoraged` and activates the libvirt network.
2. **Build:** renders the Containerfile and runs `podman build --pull=newer`. It compares image IDs to tell whether anything changed, and pushes to `image_registry` if one is set.
3. **Podman mode:** installs `/etc/containers/systemd/<vm_name>.container` and starts `<vm_name>.service`. The service restarts only when the unit file or the image changed.
4. **KVM mode:** generates a qcow2 with `bootc-image-builder`, but only when the image or `config.toml` changed. It then copies the disk to `/var/lib/libvirt/images/<vm_name>.qcow2`, runs `virt-install`, and prints the `ssh` command once the VM gets an IP address.

## Post-Deployment

### Access the instance

* **KVM:** use the `ssh goose@<ip>` command printed at the end of the run, or `sudo virsh console goose-admin-node`.
* **Podman:**
  ```bash
  sudo podman exec -it goose-admin-node /bin/bash
  ```

### Register with Red Hat Insights

If you supplied `insights_org_id` and `insights_activation_key`, `goose-register.service` registers the system on first boot. Check it with:

```bash
sudo systemctl status goose-register.service
sudo insights-client --status
```

Otherwise, register manually:

```bash
sudo subscription-manager register --org <org> --activationkey <key>   # or --username
sudo insights-client --register
```

`insights-client --register` also enables the `insights-client` timer for scheduled uploads.

> **Podman mode caveat:** the image's `/etc/rhsm-host` symlink points to `/run/secrets/rhsm`. When that path exists, `subscription-manager` switches to container mode and refuses to register. On a Fedora host the path doesn't exist and registration works, which has been tested. On a **registered RHEL host**, Podman mounts the host's secrets at `/run/secrets`, so registering from inside the container will probably fail. In both cases, Insights data describes a container, not real hardware. For a node that shows up in Insights as a full fleet member, use KVM mode.

### Start Goose

```bash
goose session
```

Authenticate with your Red Hat credentials if prompted. Run `goose --help` to see the subcommands available in the installed version.

## Maintenance and Updates

In Image Mode, the OS is updated by replacing the image, not by running `dnf update` on the live system.

1. Change the image: edit `extra_packages`, `templates/Containerfile.j2` or the base image.
2. Re-run the playbook. Add `-e build_no_cache=true` to pick up newer RPMs when the Containerfile hasn't changed.
3. Roll out the update:
   * **Podman:** handled automatically. The service restarts onto the new image, and `/var` persists in the `<vm_name>-var` volume.
   * **KVM with `image_registry` set:** the VM tracks the registry image, so update in place from inside the VM:
     ```bash
     sudo bootc upgrade --apply      # pulls the new image and reboots
     sudo bootc rollback             # if needed
     ```
     For a private registry, put credentials in `/etc/ostree/auth.json` on the VM.
   * **KVM without a registry:** re-run with `-e vm_recreate=true`. This destroys the VM and its disk, including any data in `/var`, and boots a fresh one.

## Teardown

`teardown-goose-server.yml` removes everything the deploy creates so you can start again from a clean slate. It cleans up **both** modes no matter what `deployment_mode` is set to, and it's safe to run when nothing, or only part of the deployment, exists.

```bash
ansible-playbook teardown-goose-server.yml -K                          # asks for confirmation
ansible-playbook teardown-goose-server.yml -K -e teardown_confirm=yes  # no prompt
```

In order, it:

1. **Unregisters** from Insights and RHSM, so repeated runs don't leave stale systems in console.redhat.com. For the container it uses `podman exec`. For the VM it uses SSH as `admin_user` with your key. If the VM can't be reached, the run prints a warning instead of failing; remove the system from the [Insights inventory](https://console.redhat.com/insights/inventory) by hand.
2. **Podman:** stops `<vm_name>.service`, removes the Quadlet file, reloads systemd, then removes the container and the `<vm_name>-var` volume.
3. **KVM:** stops the VM and runs `virsh undefine --remove-all-storage`, then removes the disk at `/var/lib/libvirt/images/<vm_name>.qcow2`.
4. **Images:** removes the locally built image tag(s).
5. **Build directory:** deletes `build_dir`, including the Containerfile, credstore (registration secrets) and qcow2 output.

| Variable | Default | Purpose |
|---|---|---|
| `teardown_confirm` | prompt | Set to `yes` to skip the confirmation prompt |
| `teardown_unregister` | `true` | Unregister from RHSM/Insights before destroying |
| `teardown_remove_base_images` | `false` | Also delete the base image and the bootc-image-builder image (forces a full re-pull) |

These are **left in place** on purpose, so the next deploy is fast and doesn't need setting up again: installed packages, the libvirt daemons and network, registry logins, `rhsm_secrets_dir`, and any image pushed to `image_registry`.

### Repeatable test cycle

```bash
ansible-playbook teardown-goose-server.yml -K -e teardown_confirm=yes && \
ansible-playbook deploy-goose-server.yml   -K -e @secrets.yml
```

## Troubleshooting

* **`No working registry.redhat.io login found`:** run `podman login registry.redhat.io`. The error includes Podman's own message. Logins stored under `/run/...` are cleared on reboot, so log in again after restarting.
* **`No match for argument: goose-redhat` / repo errors during the build:** the build can't see RHEL repositories. On RHEL, check `sudo subscription-manager repos --list-enabled`. On other hosts, check the `rhsm_secrets_dir` contents and how old the certificates are.
* **bootc-image-builder failures:** check free space in `/var/lib/containers` and `build_dir`.
* **VM gets no IP address:** run `sudo virsh net-list --all` and make sure the network is active. Then use `sudo virsh console <vm_name>` to look at the boot.
* **Container won't start:** run `sudo systemctl status goose-admin-node.service` and `sudo journalctl -u goose-admin-node.service`. To validate the unit, run `sudo /usr/libexec/podman/quadlet -dryrun`.
