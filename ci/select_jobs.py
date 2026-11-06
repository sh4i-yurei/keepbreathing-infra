"""Select CI driver jobs from paths changed on a branch."""

import os
import subprocess
import sys
from pathlib import Path

import yaml


def _yaml(path):
    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


def _strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from _strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from _strings(child)


def _role_names(value):
    """Find roles in plays, tasks, nested blocks and role dependencies."""
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"roles", "dependencies"} and isinstance(child, list):
                for role in child:
                    if isinstance(role, str):
                        yield role
                    elif isinstance(role, dict):
                        name = role.get("role") or role.get("name")
                        if isinstance(name, str):
                            yield name
                        else:
                            raise ValueError
                    else:
                        raise ValueError
            elif key in {
                "import_role",
                "include_role",
                "ansible.builtin.import_role",
                "ansible.builtin.include_role",
            }:
                if isinstance(child, str):
                    yield child
                elif isinstance(child, dict) and isinstance(child.get("name"), str):
                    yield child["name"]
                else:
                    raise ValueError
            else:
                yield from _role_names(child)
    elif isinstance(value, list):
        for child in value:
            yield from _role_names(child)


def _driver_jobs(root):
    tests = root / "ansible/tests"
    folders = {path.name for path in tests.iterdir() if path.is_dir()}
    workflow = _yaml(root / ".github/workflows/ci.yml")
    drivers = {}
    for job, definition in workflow["jobs"].items():
        matches = {
            folder
            for step in definition.get("steps", [])
            for run in [step.get("run", "")]
            for folder in folders
            if f"tests/{folder}/run.sh" in run
        }
        if matches:
            drivers[job] = matches
    return drivers, folders


def _dependencies(root, own_folders, test_folders):
    tests = root / "ansible/tests"
    roles_root = root / "ansible/roles"
    folders = set(own_folders)
    roles = set()
    for own in own_folders:
        for path in (tests / own).rglob("*"):
            if not path.is_file():
                continue
            if path.suffix in {".yml", ".yaml"}:
                content = _yaml(path)
            else:
                try:
                    content = path.read_text()
                except UnicodeDecodeError:
                    content = ""
            strings = list(_strings(content))
            folders.update(
                folder
                for folder in test_folders
                if any(f"tests/{folder}/" in value for value in strings)
            )
            if path.suffix in {".yml", ".yaml"}:
                roles.update(_role_names(content))
    pending = list(roles)
    while pending:
        role = pending.pop()
        for path in (roles_root / role).rglob("*"):
            if path.is_file() and path.suffix in {".yml", ".yaml"}:
                for dependency in _role_names(_yaml(path)):
                    if dependency not in roles:
                        roles.add(dependency)
                        pending.append(dependency)
    return folders, roles


def select_jobs(changed_paths, root):
    """Return whether all drivers run and the selected job IDs."""
    root = Path(root)
    drivers, test_folders = _driver_jobs(root)
    dependencies = {
        job: _dependencies(root, own, test_folders) for job, own in drivers.items()
    }
    selected = set()
    for path in changed_paths:
        parts = Path(path).parts
        if (
            len(parts) >= 4
            and parts[:2] == ("ansible", "tests")
            and parts[2] in test_folders
        ):
            selected.update(
                job for job, (folders, _) in dependencies.items() if parts[2] in folders
            )
        elif len(parts) >= 4 and parts[:2] == ("ansible", "roles"):
            selected.update(
                job for job, (_, roles) in dependencies.items() if parts[2] in roles
            )
        elif (
            (
                len(parts) == 3
                and parts[:2] == ("ansible", "tests")
                and path.endswith(".py")
            )
            or parts[:1] in {("workstation",), ("tailscale",)}
            or parts[:2] == ("ansible", "playbooks")
            or (path.endswith(".md") and parts[:2] != ("ansible", "roles"))
        ):
            continue
        else:
            return True, set(drivers)
    return False, selected


def _git(root, *args):
    return subprocess.run(
        ["git", *args], cwd=root, check=True, capture_output=True, text=True
    ).stdout.strip()


def main(event_name=None, ref=None, root=None):
    """Write the GitHub Actions outputs, failing open to all drivers."""
    root = Path(root) if root is not None else Path(__file__).resolve().parents[1]
    output = Path(os.environ["GITHUB_OUTPUT"])
    try:
        drivers, _ = _driver_jobs(root)
        if event_name != "push" or ref == "refs/heads/main":
            full, jobs = True, set(drivers)
        else:
            base = _git(root, "merge-base", "HEAD", "origin/main")
            paths = _git(root, "diff", "--name-only", base, "HEAD").splitlines()
            full, jobs = select_jobs(paths, root)
            if full:
                jobs = set(drivers)
    except Exception:
        full = True
        try:
            drivers, _ = _driver_jobs(root)
        except Exception:
            drivers = {}
        jobs = set(drivers)
    lines = [f"full={str(full).lower()}"]
    lines.extend(
        f"{job.replace('-', '_')}={str(job in jobs).lower()}" for job in sorted(drivers)
    )
    with output.open("a") as stream:
        stream.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(*sys.argv[1:3])
