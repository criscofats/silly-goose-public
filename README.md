# RHEL 10 Image Mode Server with Goose-RedHat

This project contains an Ansible playbook designed to build and deploy a Red Hat Enterprise Linux (RHEL) 10 Image Mode (`bootc`) server. The primary purpose of this server is to run `goose-redhat`—an agentic AI CLI tool—to interact with Red Hat Knowledgebase (KB) articles and troubleshoot issues across your fleet, alongside integration with Red Hat Insights.

## Features

* **Image Mode OS (`bootc`):** Builds a localized RHEL 10 OS image using standard OCI container tools (Podman).
* **Flexible Deployment:** Deploy the resulting image natively as a privileged Podman container or generate a `qcow2` disk to run as a KVM virtual machine.
* **AI-Powered Troubleshooting:** Pre-installs `goose-redhat` from the RHEL extensions repository.
* **Fleet Management:** Includes and enables `insights-client` for Red Hat Insights integration.

## Prerequisites

Before running the playbook, ensure the host machine meets the following requirements:

1. **Operating System:** A Linux host (RHEL 9/10, Fedora, or similar) with Ansible installed.
2. **Container Tools:** `podman` must be installed and configured for rootless or root operations (root/become is used in the playbook).
3. **Virtualization (If using KVM mode):** `libvirt`, `qemu-kvm`, and `virt-install` must be installed and the `libvirtd` service must be running.
4. **Red Hat Registry Access:** You must be authenticated to the Red Hat container registry to pull the base RHEL 10 bootc image and the image builder.
   ```bash
   podman login registry.redhat.io
   ```
   *(Note: You will need an active Red Hat subscription or a Red Hat Developer account).*

## Configuration

The playbook uses several variables that you can customize in the `vars` section of the `deploy-goose-server.yml` file:

* `image_name`: The local tag for your built container image (default: `goose-rhel10-troubleshooter`).
* `deployment_mode`: Choose between `"kvm"` (default) to provision a virtual machine, or `"podman"` to run it locally as an Image Mode container.
* `base_image`: The upstream RHEL 10 bootc image to use (default: `registry.redhat.io/rhel10/rhel-bootc:latest`).
* `build_dir`: The local directory where the Containerfile and output disks will be generated (default: `/opt/goose-image-build`).
* `vm_name`: The name assigned to the KVM virtual machine or Podman container (default: `goose-admin-node`).

## Execution

1. Clone this repository or download the playbook to your host machine.
2. Review and adjust the variables in the playbook as needed.
3. Run the playbook using `ansible-playbook`:

```bash
ansible-playbook deploy-goose-server.yml -K
```
*(The `-K` flag prompts for your `sudo` password, as the playbook requires escalated privileges to create directories, build images, and manage libvirt).*

## Post-Deployment Steps

Once the deployment is complete and your VM or container is running, you need to perform a few final registration steps:

### 1. Access the Instance
* **KVM Mode:** SSH into the VM or access it via the hypervisor console (`virsh console goose-admin-node`).
* **Podman Mode:** Execute an interactive shell inside the container:
  ```bash
  podman exec -it goose-admin-node /bin/bash
  ```

### 2. Register with Red Hat Insights
To enable remote management and vulnerability scanning, register the system:
```bash
insights-client --register
```

### 3. Initialize Goose-RedHat
To begin using Goose for CLI-based troubleshooting, initialize it and authenticate using your Red Hat SSO credentials if prompted:
```bash
goose session start
```

## Maintenance and Updates

Because this server relies on RHEL Image Mode (`bootc`), you should avoid running `dnf update` directly on the live system to maintain immutability. 

**To update the system or add new packages:**
1. Update the `Containerfile` definition in the Ansible playbook.
2. Re-run the playbook to generate a new OCI image.
3. Push the image to your local or private registry.
4. From inside the running Goose node, use `bootc` to pull the update and reboot:
   ```bash
   bootc switch localhost/goose-rhel10-troubleshooter:latest
   ```

## Troubleshooting

* **Build Failures:** If `bootc-image-builder` fails, ensure your host has sufficient disk space in `/var/lib/containers` and `/opt/goose-image-build`.
* **KVM Network Issues:** If the VM deploys but lacks network access, ensure the `default` libvirt network is active (`virsh net-start default`).
