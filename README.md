# Containers and Kubernetes, lab kit

This is the lab kit of "Containers and Kubernetes", the first course of [Kubernetes, hands-on](https://ashy-tree-001ac5303.6.azurestaticapps.net/). The website has the chapters and the lab tasks. This repository has everything you run: the `course` command, the scripts that build the environment of the course on your own computer, the lab scripts that check your work, the sample app and the reference solutions.

The course runs on your computer and needs no cloud account. Read the [Introduction](https://ashy-tree-001ac5303.6.azurestaticapps.net/courses/kubernetes/introduction.html) and [Setup](https://ashy-tree-001ac5303.6.azurestaticapps.net/courses/kubernetes/setup.html) pages before you run anything here.

## How it works

The labs run in a Linux shell with Docker Engine, kind, kubectl and a local registry.

- On Windows, that shell is a WSL distribution named `kubernetes-labs`, kept for the course. `.\course.ps1 up` creates it from stock Ubuntu, installs the tools and clones this kit inside it, in `~/kubernetes-labs`.
- On Linux, it is your machine. `./course up` lists the tools it installs and asks first.
- On macOS, `./course up` installs nothing. It checks the tools you installed and creates the registry. macOS is not tested yet.

Your own work goes in `~/work`, outside the kit, so an update of the kit never touches it.

## Get started

1. Clone the kit.

   ```bash
   git clone https://github.com/<account>/kubernetes-labs.git
   cd kubernetes-labs
   ```

2. Build the environment. The command says what it creates and asks before it changes anything. It is safe to run twice.

   ```bash
   ./course up          # Linux or macOS
   .\course.ps1 up      # Windows, in PowerShell
   ```

3. Run the readiness report, then start the first lab. On Windows, open the distribution first with `.\course.ps1 connect`.

   ```bash
   course check
   course start 01
   ```

On Windows, the distribution stops a few seconds after its last terminal closes. Your work and your cluster are kept. When you come back, `course start NN` brings your lab back and says where you stand.

## Commands

The environment. On Linux, run them from the kit folder as `./course`, or as `course` once `./course up` has put a launcher in `~/.local/bin`. On Windows, run them in PowerShell from the kit folder as `.\course.ps1`, with `-Yes` instead of `--yes`.

| Command | What it does |
|---|---|
| `course up [--yes]` | Builds the environment: the tools, the registry on `localhost:5001`, the launcher. Safe to run twice |
| `course connect` | On Windows, opens a terminal in the distribution. On Linux, says that you are already in the environment |
| `course status` | Shows the tools, the registry and the cluster |
| `course check` | Readiness report of the environment. It changes nothing |
| `course stop` | On Windows, stops the distribution. Your work and your cluster are kept |
| `course destroy [--yes]` | On Windows, deletes the distribution with everything in it, `~/work` included. On Linux, removes the cluster, the registry with its data and the launcher, and keeps Docker, kind, kubectl and `~/work` |
| `course update` | Updates the kit with `git pull` |

The labs, in the environment, from any folder:

| Command | What it does |
|---|---|
| `course start NN [--yes]` | Sets up lab `NN`, or brings it back after a stop, then says where you stand |
| `course check NN` | Checks your work on lab `NN`. Add `--guided` to go task by task, `--stage N` for one stage, `--deep` for the live tests, `--next` for the next task only |
| `course break NN` | Puts one fault into your finished lab for you to find. `--diagnose` checks your answer, `--restore` puts the lab back |
| `course solution NN [--yes]` | Copies the reference solution into `~/work/NN-name`, after asking. Files it replaces go to `~/work/.backup` first |
| `course clean NN [--yes]` | Removes what lab `NN` created. Your files and the registry are kept |

## What is in the kit

| Path | Content |
|---|---|
| `course`, `course.ps1` | The course command, in bash and in PowerShell |
| `.env.example` | Optional settings for Windows, copied to `.env` |
| `setup/` | The install script of the tools, the cloud-init file and the environment script of the WSL distribution, and the readiness report |
| `labs/NN-name/` | One folder per lab: setup, validation, teardown and broken lab scripts, and the kind configuration of a lab with a cluster |
| `lib/` | Shared functions of the scripts, the staged validator and the broken lab engine |
| `sample-app/` | The small Go web app used in every lab |
| `solutions/NN-name/` | Reference solutions, laid out like your work folder `~/work/NN-name` |
| `extras/azure-lab-vm/` | The frozen files of the Azure lab VM that the course used before. The `course` command does not use them |
| `tools/check-kit.py` | Checks of the kit for contributors |

## For contributors

The style guide of the course website sets the rules for scripts. Before a change, run these from the kit folder:

```bash
shellcheck -x course setup/*.sh labs/*/*.sh lib/*.sh
pwsh -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
(cd sample-app && go vet ./... && go test ./...)
python3 tools/check-kit.py
```

The checker of the course website also reads this kit. It compares the stages of each validator with the tasks on the chapter page, and checks that every `course` command and every file link on a page exists here.
