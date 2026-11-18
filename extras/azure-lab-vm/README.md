# Azure lab VM, frozen

Before the course ran on your own computer, its labs ran on a small Linux VM in Azure. This folder keeps the files of that path for someone who cannot run WSL 2. It gets no new feature, no test and no fix, and the `course` command no longer uses it.

- `infra/` holds the Terraform files and the cloud-init file that created the lab VM, its network, its budget and its auto-shutdown.
- `labs/01-containers/infra/` holds the Terraform file of the Azure Container Registry that lab 1 used then.
- `kit-on-vm.sh` is the part of the old `course up` that ran on the VM.

The files still use the old names (`aro-k8s`) and expect the `course` command of that time, which created the Terraform state in Azure Storage and ran these files. That version of the kit, as it was tested on the VM, is the Git tag `v1-azure-vm`:

```bash
git clone --branch v1-azure-vm https://github.com/<account>/kubernetes-labs.git
```

Its README and the Setup page of the course at the same date explain each step and what it costs. Everything it creates is billed to your Azure subscription.

After a reboot of the lab VM, the control plane of the kind cluster may not come back by itself: `docker start aro-k8s-control-plane` repairs it.
