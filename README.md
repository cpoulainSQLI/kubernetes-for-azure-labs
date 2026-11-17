# Kubernetes and Azure Red Hat OpenShift, lab kit

This is the lab kit of the course "Kubernetes and Azure Red Hat OpenShift, hands-on". The [course website](https://ashy-tree-001ac5303.6.azurestaticapps.net/) has the chapters, the lab tasks and the costs. This repository has everything you run: the `course` command, the scripts that build your lab environment in your own Azure subscription, the lab scripts that check your work, the sample app and the reference solutions.

Read the [Introduction](https://ashy-tree-001ac5303.6.azurestaticapps.net/introduction.html) and [Setup](https://ashy-tree-001ac5303.6.azurestaticapps.net/setup.html) pages of the course website before you run anything here. They explain what each command creates and what it costs.

## How it works

You work from two places:

- Your own computer is where you clone this kit. There, the `course` command creates a small Linux VM in your Azure subscription, starts and stops it, and opens SSH sessions on it.
- The lab VM is where you do the labs. It clones this kit into `~/aro-k8s-course` when it is created, and puts the `course` command on its `PATH`. Your own work goes in `~/work`, outside the kit, so an update of the kit never touches it.

## Get started

1. Install the Azure CLI, Terraform 1.17.0 or later, Git and an OpenSSH client. The Setup page of the course website gives the commands for Windows, macOS and Linux.
2. Clone the kit. A fork is optional, for when you want to keep your own changes on GitHub. The lab VM clones the same repository as your computer without credentials, so a fork must be public.

   ```bash
   git clone https://github.com/<account>/kubernetes-for-azure-labs.git
   cd kubernetes-for-azure-labs
   ```

3. Create an SSH key pair for the course, and copy `.env.example` to `.env`. Fill in `.env`, at least `LEARNER_IP`. The comments in the file explain each setting. `.env` holds nothing secret and Git ignores it.
4. Sign in with `az login`, then create the lab environment. The command prints the estimated cost and asks before it changes anything.

   ```bash
   ./course up          # macOS, Linux or Git Bash
   .\course.ps1 up      # Windows PowerShell
   ```

5. Run the readiness report, connect to the lab VM and start the first lab.

   ```bash
   ./course check
   ./course connect
   course start 01      # on the lab VM
   ```

At the end of every session, stop the lab VM with `./course stop`. Start it again next time with `./course up`.

## Commands

On your own computer, from the kit folder. In PowerShell, write `.\course.ps1` instead of `./course`, and `-Yes` or `-Apply` instead of `--yes` or `--apply`.

| Command | What it does |
|---|---|
| `./course up [--yes] [--apply]` | Creates the lab environment, or starts the lab VM when it exists. Safe to run twice. `--apply` also applies a change made to `.env` |
| `./course connect` | Opens an SSH session on the lab VM |
| `./course ssh-config` | Prints the SSH settings of the lab VM, to paste into `~/.ssh/config` for VS Code Remote - SSH |
| `./course status` | Shows the power state, the IP address and the shutdown time of the lab VM |
| `./course check` | Readiness report of the lab environment. It changes nothing |
| `./course stop` | Deallocates the lab VM. The compute charges stop and your work stays |
| `./course destroy [--yes]` | Deletes the lab environment and the Terraform state. Your work on the lab VM is lost |
| `./course update` | Updates the kit with `git pull`, then the kit on the lab VM if it runs |

On the lab VM, in any folder:

| Command | What it does |
|---|---|
| `course start NN [--yes]` | Sets up lab `NN`, for example `course start 01` |
| `course check NN` | Checks your work on lab `NN`. Add `--guided` to go task by task, `--stage N` for one stage, `--deep` for the live tests |
| `course break NN` | Puts one fault into your finished lab for you to find. `--diagnose` checks your answer, `--restore` puts the lab back |
| `course solution NN [--yes]` | Copies the reference solution into `~/work/NN-name`, after asking. Files it replaces go to `~/work/.backup` first |
| `course clean NN [--yes]` | Removes what lab `NN` created |
| `course update` | Updates the kit with `git pull` |

## What is in the kit

| Path | Content |
|---|---|
| `course`, `course.ps1` | The course command, in bash and in PowerShell |
| `.env.example` | Template for your settings |
| `setup/` | The lab VM: its Terraform files and cloud-init in `setup/infra`, the readiness report, and the script that checks the kit on the VM |
| `labs/NN-name/` | One folder per lab: setup, validation, teardown and broken lab scripts, and the Terraform files of the lab in `infra` when it creates Azure resources |
| `lib/` | Shared functions of the scripts, the staged validator and the broken lab engine |
| `sample-app/` | The small Go web app used in every lab |
| `solutions/NN-name/` | Reference solutions, laid out like your work folder `~/work/NN-name` |
| `tools/check-kit.py` | Checks of the kit for contributors |

## Updates

Follow the `main` branch. `./course update` pulls the latest kit on your computer and on the lab VM. Your `.env` and your work in `~/work` are not part of the kit, so an update never changes them.

## For contributors

The style guide of the course website sets the rules for scripts and Terraform files. Before a change, run these from the kit folder:

```bash
shellcheck -x course setup/*.sh labs/*/*.sh lib/*.sh
pwsh -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
terraform fmt -check -recursive
for d in setup/infra labs/*/infra; do terraform -chdir="$d" init -backend=false -input=false > /dev/null && terraform -chdir="$d" validate; done
(cd sample-app && go vet ./... && go test ./...)
python3 tools/check-kit.py
```

The checker of the course website also reads this kit. It compares the stages of each validator with the tasks on the chapter page, and checks that every `course` command and every file link on a page exists here.
