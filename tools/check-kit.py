#!/usr/bin/env python3
"""Checks of the kit that linters do not cover. Run from anywhere:

    python3 tools/check-kit.py

Checks:
  1. No subscription or tenant ID (any GUID except built-in role IDs), public IP address,
     e-mail address or secret in any file, and no em or en dash outside the licence files.
  2. Every name derives from the kit name: lib.sh, lib.ps1 and the kind configuration agree on it,
     and the names of the former course (aro-k8s) only remain in the frozen files of extras/.
  3. The pinned kind and kubectl versions agree across files. Terraform in extras/ still tags
     every Azure resource, and no script creates an Azure resource without tags.
  4. The bash and PowerShell versions of the commands for your own computer (course and
     course.ps1, setup/check.sh and setup/check.ps1) have the same "# check:" and "# step:" IDs,
     PowerShell files are plain ASCII, and they pass az no query that cmd.exe breaks, such as length(@).
  5. Each lab has its setup, validation and teardown scripts, a validator defines WORK_DIR and has one
     check function and one task text per stage, and a broken lab has the functions of each fault.
  6. The course command lists its commands, and course.ps1 accepts every command of the environment.
  7. The scripts are executable in the Git index, and README.md files are the only Markdown files and
     follow the writing rules.

The checker of the website compares its pages with this kit (stages, course commands, file links).
Optional: PRIVATE_TERMS="name one,name two" also searches for terms that must never appear in the
kit. Never write those terms in a file of the kit. Only the Python standard library is needed.
Exit code 0 when no error is found, 1 otherwise.
"""
import ipaddress
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Names the checks leave alone: tool folders, and what Git ignores on the author's computer (the local
# notes, the agent instructions and .claude). .terraform holds the providers that terraform init downloads.
SKIP_NAMES = {".git", "handoff", "CLAUDE.md", "CLAUDE.local.md", ".claude", ".terraform", "__pycache__"}
TEXT_SUFFIXES = {".md", ".sh", ".ps1", ".psd1", ".tf", ".hcl", ".yaml", ".yml", ".go", ".mod", ".py", ".json", ".example", ""}
# IDs of Azure built-in roles: identical in every tenant, so they are not personal data.
ALLOWED_GUIDS = {
    "b24988ac-6180-42a0-ab88-20f7382dd24c",  # Contributor
    "8311e382-0749-4cb8-b61a-304f252e45ec",  # AcrPush
}
FILLER_WORDS = ["robust", "seamless", "seamlessly", "tailored", "foster", "fostering", "genuinely", "leverage", "delve", "crucial"]
PROPER_PHRASES = ["Azure Red Hat OpenShift", "Red Hat", "Microsoft Entra ID", "Git Bash", "Windows PowerShell"]
PROPER_WORDS = {
    "Azure", "Kubernetes", "OpenShift", "Docker", "Microsoft", "Terraform", "Ubuntu", "Go", "Git", "GitHub",
    "Bash", "PowerShell", "Windows", "Linux", "macOS", "ARO", "AKS", "VM", "SSH",
}
# Scripts for your own computer exist in bash and PowerShell with the same check and step IDs.
LAPTOP_SCRIPT_PAIRS = [
    ("course", "course.ps1"),
    ("setup/check.sh", "setup/check.ps1"),
]
REQUIRED_LAB_SCRIPTS = ("setup.sh", "validate.sh", "teardown.sh")

errors = []


def relative(path):
    return path.relative_to(ROOT).as_posix()


def report(path, line_no, message):
    errors.append(f"{relative(path)}:{line_no}: {message}")


def iter_files():
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file() or any(part in SKIP_NAMES for part in path.relative_to(ROOT).parts):
            continue
        if path.suffix in TEXT_SUFFIXES or path.name in {"Dockerfile", ".gitignore", ".gitattributes", ".shellcheckrc"}:
            yield path


def is_bash(path):
    return path.suffix == ".sh" or (path.parent == ROOT and path.name == "course")


# ---------------------------------------------------------------------------
# Every file
# ---------------------------------------------------------------------------


# The licence files hold the official texts, which the writing rules do not apply to.
LICENCE_NAMES = {"LICENSE", "LICENSE-CODE"}
FORMER_NAMES = re.compile(r"aro-k8s|arok8s|ARO_K8S")


def check_text(path, text, private_terms):
    secret_patterns = [
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
        r"AccountKey=",
        r"SharedAccessSignature",
        r"\beyJ[A-Za-z0-9_-]{15,}\.",
        r"ssh-(ed25519|rsa) AAAA[0-9A-Za-z+/]{20,}",
        r"(?i)\bpassword\s*[:=]\s*\S+",
        r"(?i)client_secret\s*[:=]\s*\S+",
    ]
    for number, line in enumerate(text.splitlines(), start=1):
        if (chr(0x2014) in line or chr(0x2013) in line) and path.name not in LICENCE_NAMES:
            report(path, number, "em or en dash")
        frozen = relative(path).startswith("extras/") or path.name == "check-kit.py"
        if not frozen and FORMER_NAMES.search(line):
            report(path, number, "name of the former course (aro-k8s): names derive from the kit name")
        for guid in re.findall(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", line):
            if guid.lower() not in ALLOWED_GUIDS:
                report(path, number, "GUID (possible subscription or tenant ID)")
        for candidate in re.findall(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])", line):
            try:
                address = ipaddress.ip_address(candidate)
            except ValueError:
                continue
            if not (address.is_private or address.is_loopback or address.is_unspecified):
                report(path, number, f"public IP address {candidate}")
        if re.search(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b", line):
            report(path, number, "e-mail address")
        if path.name != "check-kit.py":
            for pattern in secret_patterns:
                if re.search(pattern, line):
                    report(path, number, f"possible secret ({pattern})")
        for term in private_terms:
            if term.lower() in line.lower():
                report(path, number, "private term from PRIVATE_TERMS")


def check_markdown(path, text):
    in_fence = False
    for number, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        prose = re.sub(r"`[^`]*`", "", re.sub(r"\]\([^)]*\)", "]", line))
        if ";" in prose:
            report(path, number, "semicolon in prose")
        if re.search(r"\((e\.g\.|eg)\b", prose, re.IGNORECASE):
            report(path, number, "'eg' in brackets: write 'for example'")
        if "**" in prose:
            report(path, number, "bold text")
        for word in FILLER_WORDS:
            if re.search(rf"\b{word}\b", prose, re.IGNORECASE):
                report(path, number, f"filler word '{word}'")
        heading = re.match(r"^#{1,6}\s+(.*)$", prose)
        if heading:
            title = heading.group(1)
            for phrase in PROPER_PHRASES:
                title = title.replace(phrase, phrase.split()[0])
            words = re.findall(r"[A-Za-z][A-Za-z0-9'\-]*", title)
            for word in words[1:]:
                if word not in PROPER_WORDS and not word.isupper() and any(c.isupper() for c in word):
                    report(path, number, f"heading not in sentence case: '{word}'")
        for target in re.findall(r"\]\(([^)\s]+)\)", line):
            if not re.match(r"^[a-z]+:", target) and not (path.parent / target.partition("#")[0]).exists():
                report(path, number, f"broken link: {target}")


# ---------------------------------------------------------------------------
# Azure tags
# ---------------------------------------------------------------------------


def check_terraform_tags(path, text):
    """Every resource carries tags = local.tags, or follows a "# untaggable:" comment that says why."""
    lines = text.splitlines()
    uses_tags = False
    for index, line in enumerate(lines):
        match = re.match(r'^resource\s+"(\w+)"\s+"(\w+)"\s*\{', line)
        if not match:
            continue
        block = []
        for following in lines[index + 1:]:
            if following.startswith("}"):
                break
            block.append(following)
        has_tags = any(re.match(r"^\s{2}tags\s*=\s*local\.tags\s*$", entry) for entry in block)
        marked = any("# untaggable:" in previous for previous in lines[max(0, index - 3):index])
        uses_tags = uses_tags or has_tags
        if not has_tags and not marked:
            report(path, index + 1, f"resource {match.group(1)}.{match.group(2)} has no 'tags = local.tags' and no '# untaggable:' comment")
    if uses_tags:
        # local.tags may be defined in another file of the same configuration folder.
        folder = "\n".join(tf.read_text(encoding="utf-8") for tf in sorted(path.parent.glob("*.tf")))
        if not re.search(r'course\s*=\s*"aro-k8s"', folder) or not re.search(r"chapter\s*=\s*var\.chapter\b", folder):
            report(path, 1, 'local.tags is not defined with course = "aro-k8s" and chapter = var.chapter in this folder')


def check_script_tags(path, text):
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if is_bash(path):
            create = re.search(r"\baz\s+([a-z-]+(?:\s+[a-z-]+)*)\s+create\b", stripped)
            # Role assignments and blob containers do not accept tags.
            untaggable = ("deployment", "role assignment", "storage container-rm")
            if create and not create.group(1).startswith(untaggable) and "--tags" not in stripped:
                report(path, number, f"'az {create.group(1)} create' without --tags")
        elif "'create'" in stripped and "'--tags'" not in stripped and not any(
            word in stripped for word in ("'deployment'", "'assignment'", "'container-rm'")
        ):
            report(path, number, "az create call without '--tags'")


# On Windows az is a batch file, so cmd.exe reads its arguments again. PowerShell quotes an argument only when it
# holds a space, and cmd.exe rejects an unquoted one with parentheses or &|<>^, such as length(@).
CMD_SPECIAL_QUERY = re.compile(r"""'--query',\s*(['"])([^'"\s]*[()&|<>^][^'"\s]*)\1""")


def check_powershell_queries(path, text):
    for number, line in enumerate(text.splitlines(), start=1):
        match = CMD_SPECIAL_QUERY.search(line)
        if match and not line.strip().startswith("#"):
            report(path, number, f"az query {match.group(2)} has a cmd.exe character and no space: az.cmd breaks on it")


# ---------------------------------------------------------------------------
# Versions, parity and the course command
# ---------------------------------------------------------------------------


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def check_version_pins():
    lib, lib_ps = read("lib/lib.sh"), read("lib/lib.ps1")
    install = read("setup/install-tools.sh")
    kind_file = read("labs/02-kubernetes-core/kind-cluster.yaml")
    pins = {
        "lib.sh kind": re.search(r'PINNED_KIND_VERSION="([^"]+)"', lib),
        "lib.ps1 kind": re.search(r"\$PinnedKindVersion = '([^']+)'", lib_ps),
        "install-tools.sh kind": re.search(r'^KIND_VERSION="([^"]+)"', install, re.MULTILINE),
        "lib.sh kubectl": re.search(r'PINNED_KUBECTL_MINOR="([^"]+)"', lib),
        "lib.ps1 kubectl": re.search(r"\$PinnedKubectlMinor = '([^']+)'", lib_ps),
        "install-tools.sh kubectl": re.search(r'^KUBECTL_MINOR="([^"]+)"', install, re.MULTILINE),
    }
    missing = [name for name, match in pins.items() if not match]
    if missing:
        errors.append(f"version pins: not found in {missing}")
        return
    kind_versions = {pins[name].group(1) for name in pins if name.endswith("kind")}
    kubectl_versions = {pins[name].group(1) for name in pins if name.endswith("kubectl")}
    if len(kind_versions) != 1:
        errors.append(f"version pins: kind versions differ {sorted(kind_versions)}")
    if len(kubectl_versions) != 1:
        errors.append(f"version pins: kubectl versions differ {sorted(kubectl_versions)}")
    if next(iter(kind_versions)) not in kind_file:
        errors.append("version pins: kind-cluster.yaml does not mention the pinned kind version")
    node_versions = set(re.findall(r"kindest/node:(v\d+\.\d+)\.\d+@sha256:[0-9a-f]{64}", kind_file))
    if node_versions != kubectl_versions:
        errors.append(f"version pins: kind node images {sorted(node_versions)} do not match kubectl {sorted(kubectl_versions)}")


def check_kit_name():
    """lib.sh, lib.ps1 and every kind configuration use the same kit name."""
    lib = re.search(r'^KIT_NAME="([a-z0-9-]+)"$', read("lib/lib.sh"), re.MULTILINE)
    lib_ps = re.search(r"^\$KitName = '([a-z0-9-]+)'$", read("lib/lib.ps1"), re.MULTILINE)
    if not lib or not lib_ps:
        errors.append("kit name: KIT_NAME in lib/lib.sh or $KitName in lib/lib.ps1 is missing")
        return
    if lib.group(1) != lib_ps.group(1):
        errors.append(f"kit name: lib/lib.sh says {lib.group(1)} and lib/lib.ps1 says {lib_ps.group(1)}")
    if not lib.group(1).endswith("-labs"):
        errors.append(f"kit name: {lib.group(1)} does not follow the pattern <course>-labs")
    for config in sorted(ROOT.glob("labs/*/kind-cluster.yaml")):
        name = re.search(r"^name:\s*(\S+)", config.read_text(encoding="utf-8"), re.MULTILINE)
        if not name or name.group(1) != lib.group(1):
            errors.append(f"kit name: {relative(config)} does not name its cluster {lib.group(1)}")


def check_parity():
    for bash_file, ps_file in LAPTOP_SCRIPT_PAIRS:
        ids = []
        for name in (bash_file, ps_file):
            ids.append(set(re.findall(r"^\s*# (check|step): ([a-z0-9-]+)", read(name), re.MULTILINE)))
        if ids[0] != ids[1]:
            only_bash = sorted(f"{kind}: {name}" for kind, name in ids[0] - ids[1])
            only_ps = sorted(f"{kind}: {name}" for kind, name in ids[1] - ids[0])
            errors.append(f"parity: {bash_file} and {ps_file} differ. Only in bash: {only_bash}. Only in PowerShell: {only_ps}")
        elif not ids[0]:
            errors.append(f"parity: {bash_file} has no check or step IDs")


def course_commands():
    """The commands of the course command, from its ENV_COMMANDS and LAB_COMMANDS lines."""
    text = read("course")
    sides = {}
    for side in ("ENV", "LAB"):
        match = re.search(rf'^{side}_COMMANDS="([a-z -]+)"$', text, re.MULTILINE)
        sides[side] = set(match.group(1).split()) if match else set()
    return sides


def check_course_command():
    sides = course_commands()
    text = read("course")
    for side, commands in sides.items():
        if not commands:
            errors.append(f"course: no {side}_COMMANDS line")
        for command in commands:
            if not re.search(rf"^\s+[a-z| -]*\b{re.escape(command)}\b[a-z| -]*\)", text, re.MULTILINE):
                errors.append(f"course: {side.lower()} command '{command}' has no branch in its case statement")
    accepted = re.search(r"\[ValidateSet\(([^)]*)\)\]", read("course.ps1"))
    accepted = set(re.findall(r"'([a-z-]+)'", accepted.group(1))) if accepted else set()
    for command in sides["ENV"] - accepted:
        errors.append(f"course.ps1: the command '{command}' is missing from its ValidateSet")


# ---------------------------------------------------------------------------
# Labs
# ---------------------------------------------------------------------------


def check_labs():
    labs = sorted(path for path in (ROOT / "labs").iterdir() if path.is_dir())
    names = {lab.name for lab in labs}
    for lab in labs:
        if not re.match(r"^\d{2}-[a-z0-9-]+$", lab.name):
            errors.append(f"labs: {relative(lab)} is not named NN-name")
        for script in REQUIRED_LAB_SCRIPTS:
            if not (lab / script).is_file():
                errors.append(f"labs: {relative(lab)} has no {script}")
    for solution in sorted(path for path in (ROOT / "solutions").iterdir() if path.is_dir()):
        if solution.name not in names:
            errors.append(f"solutions: {relative(solution)} matches no folder in labs/")


def check_validator_stages():
    """A staged validator has one check function and one task text per stage."""
    for script in sorted(ROOT.glob("labs/*/validate.sh")):
        text = script.read_text(encoding="utf-8")
        name = relative(script)
        if "lib-validate.sh" not in text:
            errors.append(f"stages: {name} does not use lib/lib-validate.sh")
            continue
        if not re.search(r'^WORK_DIR="', text, re.M):
            errors.append(f"stages: {name} defines no WORK_DIR, so course check cannot tell a lab that is not started")
        titles = re.search(r"^STAGE_TITLES=\(\n(.*?)^\)", text, re.S | re.M)
        count = len(re.findall(r'^\s+"', titles.group(1), re.M)) if titles else 0
        if count == 0:
            errors.append(f"stages: {name} defines no STAGE_TITLES")
            continue
        for number in range(1, count + 1):
            for function in (f"stage_{number}", f"stage_{number}_task"):
                if not re.search(rf"^{function}\(\) {{", text, re.M):
                    errors.append(f"stages: {name} has no function {function}")
        if re.search(rf"^stage_{count + 1}\(\) {{", text, re.M):
            errors.append(f"stages: {name} has more stage functions than titles")


def check_break_scripts():
    """A broken lab script has a symptom, an injection and an explanation for each fault."""
    for script in sorted(ROOT.glob("labs/*/break.sh")):
        text = script.read_text(encoding="utf-8")
        name = relative(script)
        scenarios = re.search(r"^SCENARIOS=\((.*?)\)", text, re.M)
        names = scenarios.group(1).split() if scenarios else []
        if not names:
            errors.append(f"broken lab: {name} defines no SCENARIOS")
        for scenario in names:
            for prefix in ("symptom", "inject", "explain"):
                if not re.search(rf"^{prefix}_{scenario}\(\) {{", text, re.M):
                    errors.append(f"broken lab: {name} has no function {prefix}_{scenario}")
        causes = re.search(r"^CAUSES=\(\n(.*?)^\)", text, re.S | re.M)
        if not causes or len(re.findall(r'^\s+"', causes.group(1), re.M)) <= len(names):
            errors.append(f"broken lab: {name} needs one cause per fault, plus at least one that is never the answer")
        for function in ("lab_is_finished", "restore_lab"):
            if not re.search(rf"^{function}\(\) {{", text, re.M):
                errors.append(f"broken lab: {name} has no function {function}")
        if f'BREAK_CHECK="course check {script.parent.name[:2]}' not in text:
            errors.append(f"broken lab: {name} has no BREAK_CHECK that starts with: course check {script.parent.name[:2]}")


# ---------------------------------------------------------------------------
# Git index and Markdown
# ---------------------------------------------------------------------------


def check_executable_bits():
    """Scripts that Git already tracks are executable in the index, so that a clone on Linux can run them."""
    try:
        listing = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-s"], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return
    for line in listing.splitlines():
        meta, _, name = line.partition("\t")
        mode = meta.split()[0]
        if (name == "course" or name.endswith(".sh")) and mode != "100755":
            errors.append(f"{name}: not executable in the Git index. Run: git update-index --chmod=+x {name}")


def check_markdown_files():
    for path in sorted(ROOT.rglob("*.md")):
        if any(part in SKIP_NAMES for part in path.relative_to(ROOT).parts):
            continue
        if path.name == "README.md":
            check_markdown(path, path.read_text(encoding="utf-8"))
        else:
            errors.append(f"{relative(path)}: Markdown file. README.md files are the only Markdown files of the kit")


def main():
    private_terms = [term.strip() for term in os.environ.get("PRIVATE_TERMS", "").split(",") if term.strip()]
    files = list(iter_files())
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        check_text(path, text, private_terms)
        if path.suffix == ".tf":
            check_terraform_tags(path, text)
        if is_bash(path) or path.suffix == ".ps1":
            check_script_tags(path, text)
        if path.suffix == ".ps1":
            check_powershell_queries(path, text)
        if path.suffix in {".ps1", ".psd1"} and not text.isascii():
            # Windows PowerShell 5.1 reads files without a byte order mark as ANSI, not UTF-8.
            report(path, 1, "non-ASCII character in a PowerShell file")
    check_version_pins()
    check_kit_name()
    check_parity()
    check_course_command()
    check_labs()
    check_validator_stages()
    check_break_scripts()
    check_executable_bits()
    check_markdown_files()

    for error in errors:
        print(f"[FAIL] {error}")
    print(f"\nChecked {len(files)} files, {len(errors)} errors"
          + (f", with {len(private_terms)} private terms" if private_terms else ", without PRIVATE_TERMS") + ".")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
