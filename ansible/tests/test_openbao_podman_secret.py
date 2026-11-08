"""Exercise openbao-podman-secret, Podman's shell secret driver, through its command line.

Podman runs each command with SECRET_ID set to its 25-character hex ID, hands store the
secret's data on standard input, and takes lookup's standard output as the value (OpenBao on
the hub decision 62). The tests call main in process with the account's home replaced, and
replace os.execv so lookup's hand-over to openbao-read is recorded instead of run.
"""

import io
import os
import pwd
import stat
import subprocess
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace

import pytest
from load_source import load_source

driver = load_source("ansible/roles/openbao_client/files/openbao-podman-secret.py")
SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "roles/openbao_client/files/openbao-podman-secret.py"
)

# Two IDs Podman gave in the rehearsal of 2026-11-08.
FIRST = "a134b9626fd9d45bfbfe8df7d"
SECOND = "acf83ffe43d222a9978743894"
USAGE = "openbao-podman-secret: usage: openbao-podman-secret store|lookup|delete|list\n"
ID_MESSAGE = "openbao-podman-secret: SECRET_ID must be 25 lowercase hex characters\n"
SHAPE_MESSAGE = (
    "openbao-podman-secret: store needs <consumer>/<name>, "
    "each matching ^[a-z][a-z0-9-]*$\n"
)
FOLDER = ".config/openbao/podman-secrets"
# The runner's own HOME, before a test points it at a decoy. Its user site-packages hold
# pytest, coverage and mutmut on the laptop, which the child interpreter must still find.
REAL_HOME = os.environ.get("HOME", "")


class Exec(BaseException):
    """Raised in place of os.execv. It isn't an Exception, so the driver's catch-all for
    unexpected errors can't swallow it, the way a real exec never returns."""

    def __init__(self, path, args):
        super().__init__(path, args)
        self.path = path
        self.args_given = list(args)


@pytest.fixture(autouse=True)
def umask():
    """A fixed umask that keeps every mode bit the driver asks for, restored afterwards."""
    previous = os.umask(0o022)
    yield
    os.umask(previous)


@pytest.fixture
def home(tmp_path, monkeypatch):
    """The account's home from the password database; $HOME points at an empty decoy."""
    home = tmp_path / "home"
    home.mkdir()
    decoy = tmp_path / "decoy"
    decoy.mkdir()
    monkeypatch.setenv("HOME", str(decoy))
    monkeypatch.delenv("SECRET_ID", raising=False)
    uid = os.getuid()

    def getpwuid(asked):
        if asked != uid:
            raise KeyError(f"getpwuid(): uid not found: {asked}")
        return SimpleNamespace(pw_name="clienttest", pw_uid=uid, pw_dir=str(home))

    monkeypatch.setattr(pwd, "getpwuid", getpwuid)
    return home


@pytest.fixture
def execs(monkeypatch):
    """Record lookup's os.execv instead of replacing the test process."""

    def execv(path, args):
        raise Exec(path, args)

    monkeypatch.setattr(os, "execv", execv)


def feed(monkeypatch, data):
    """Give the driver standard input holding exactly these bytes."""
    monkeypatch.setattr(sys, "stdin", io.TextIOWrapper(io.BytesIO(data)))


def run(*args):
    output = io.StringIO()
    errors = io.StringIO()
    with redirect_stdout(output), redirect_stderr(errors):
        status = driver.main(list(args))
    return status, output.getvalue(), errors.getvalue()


def store(monkeypatch, secret_id, path):
    monkeypatch.setenv("SECRET_ID", secret_id)
    feed(monkeypatch, path.encode())
    return run("store")


def folder_of(home):
    return home / FOLDER


def mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def everything_under(path):
    return sorted(str(item.relative_to(path)) for item in path.rglob("*"))


def run_program(tmp_path, home, *args, data=b"", env=None):
    """Run the file under sys.executable, the way Podman starts the installed program.

    A subprocess can't see monkeypatch, so sitecustomize replaces its account lookup.
    """
    site = tmp_path / "site"
    site.mkdir(exist_ok=True)
    (site / "sitecustomize.py").write_text(
        "import os, pwd, types\n"
        f"_home = {str(home)!r}\n"
        "_uid = os.getuid()\n"
        "def _getpwuid(uid):\n"
        "    if uid != _uid:\n"
        "        raise KeyError(uid)\n"
        "    return types.SimpleNamespace(pw_dir=_home)\n"
        "pwd.getpwuid = _getpwuid\n"
    )
    paths = [str(site), *filter(None, [os.environ.get("PYTHONPATH")])]
    inherited = {
        name: value for name, value in os.environ.items() if name != "SECRET_ID"
    }
    result = subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        input=data,
        capture_output=True,
        check=False,
        timeout=60,
        env={
            **inherited,
            "HOME": REAL_HOME,
            "PYTHONPATH": os.pathsep.join(paths),
            **(env or {}),
        },
    )
    return result.returncode, result.stdout.decode(), result.stderr.decode()


@pytest.mark.parametrize(
    "args", [(), ("store", "list"), ("read",)], ids=["none", "two", "unknown"]
)
def test_refuses_a_missing_extra_or_unknown_argument(home, args):
    assert run(*args) == (1, "", USAGE)


def test_the_installed_program_refuses_no_argument(tmp_path, home):
    assert run_program(tmp_path, home) == (1, "", USAGE)


BAD_IDS = {
    "empty": "",
    "24": "a" * 24,
    "26": "a" * 26,
    "uppercase": "a" * 24 + "A",
    "not-hex": "z" * 25,
    "traversal": "../" + "a" * 22,
}


@pytest.mark.parametrize("command", ["store", "lookup", "delete"])
@pytest.mark.parametrize(
    "secret_id", [None, *BAD_IDS.values()], ids=["unset", *BAD_IDS]
)
def test_refuses_a_missing_or_malformed_secret_id(
    tmp_path, home, monkeypatch, execs, command, secret_id
):
    if secret_id is not None:
        monkeypatch.setenv("SECRET_ID", secret_id)
    feed(monkeypatch, b"clientsvc/probe")
    assert run(command) == (1, "", ID_MESSAGE)
    assert everything_under(tmp_path) == ["decoy", "home"]


def test_store_writes_the_path_in_a_private_file_and_replaces_it(home, monkeypatch):
    assert store(monkeypatch, FIRST, "clientsvc/probe") == (0, "", "")
    folder = folder_of(home)
    assert mode(folder) == 0o700
    assert (folder / FIRST).read_bytes() == b"clientsvc/probe"
    assert mode(folder / FIRST) == 0o600
    assert os.listdir(folder) == [FIRST]

    (folder / FIRST).chmod(0o644)
    assert store(monkeypatch, FIRST, "clientsvc/other") == (0, "", "")
    assert (folder / FIRST).read_bytes() == b"clientsvc/other"
    assert mode(folder / FIRST) == 0o600
    assert store(monkeypatch, FIRST, "a/b") == (0, "", "")
    assert (folder / FIRST).read_bytes() == b"a/b"
    assert os.listdir(folder) == [FIRST]
    assert os.listdir(os.environ["HOME"]) == []


def test_store_keeps_an_existing_folder_and_its_other_secrets(home, monkeypatch):
    assert store(monkeypatch, FIRST, "clientsvc/probe") == (0, "", "")
    assert store(monkeypatch, SECOND, "othersvc/probe") == (0, "", "")
    folder = folder_of(home)
    assert (folder / FIRST).read_bytes() == b"clientsvc/probe"
    assert (folder / SECOND).read_bytes() == b"othersvc/probe"
    assert sorted(os.listdir(folder)) == [FIRST, SECOND]


def test_store_writes_inside_its_own_folder_whatever_the_system_temporary_folder(
    tmp_path, home, monkeypatch
):
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path / "no-such-folder"))
    assert store(monkeypatch, FIRST, "clientsvc/probe") == (0, "", "")
    assert (folder_of(home) / FIRST).read_bytes() == b"clientsvc/probe"


@pytest.mark.parametrize(
    "data",
    [
        b"clientsvc/probe\n",
        b"clientsvc",
        b"../etc/passwd",
        b"Clientsvc/probe",
        b"clientsvc/probe/extra",
        b"",
        b"\xff/probe",
    ],
    ids=[
        "newline",
        "no-name",
        "traversal",
        "uppercase",
        "three-parts",
        "empty",
        "binary",
    ],
)
def test_store_refuses_input_of_the_wrong_shape_without_echoing_it(
    tmp_path, home, monkeypatch, data
):
    monkeypatch.setenv("SECRET_ID", FIRST)
    feed(monkeypatch, data)
    status, output, errors = run("store")
    assert (status, output, errors) == (1, "", SHAPE_MESSAGE)
    text = data.decode(errors="replace").strip()
    if text:
        assert text not in errors
    assert everything_under(tmp_path) == ["decoy", "home"]


def test_lookup_hands_over_to_openbao_read_with_the_stored_path(
    home, monkeypatch, execs
):
    assert store(monkeypatch, FIRST, "clientsvc/probe") == (0, "", "")
    assert store(monkeypatch, SECOND, "othersvc/probe") == (0, "", "")
    monkeypatch.setenv("SECRET_ID", FIRST)
    output = io.StringIO()
    errors = io.StringIO()
    with pytest.raises(Exec) as handed_over:
        with redirect_stdout(output), redirect_stderr(errors):
            driver.main(["lookup"])
    assert handed_over.value.path == "/usr/local/bin/openbao-read"
    assert handed_over.value.args_given == ["openbao-read", "clientsvc/probe"]
    assert (output.getvalue(), errors.getvalue()) == ("", "")


@pytest.mark.parametrize("other", [False, True], ids=["no-folder", "other-secret"])
def test_lookup_without_a_stored_path_names_only_the_id(
    home, monkeypatch, execs, other
):
    if other:
        assert store(monkeypatch, SECOND, "othersvc/probe") == (0, "", "")
    monkeypatch.setenv("SECRET_ID", FIRST)
    assert run("lookup") == (
        1,
        "",
        f"openbao-podman-secret: no secret stored for {FIRST}\n",
    )


def test_lookup_reports_a_missing_openbao_read_without_its_path(home, monkeypatch):
    assert store(monkeypatch, FIRST, "clientsvc/probe") == (0, "", "")

    def execv(path, args):
        raise FileNotFoundError(2, "No such file or directory", path)

    monkeypatch.setattr(os, "execv", execv)
    monkeypatch.setenv("SECRET_ID", FIRST)
    assert run("lookup") == (
        1,
        "",
        "openbao-podman-secret: lookup failed: No such file or directory\n",
    )


def test_delete_removes_the_file_and_succeeds_when_it_is_gone(home, monkeypatch):
    assert store(monkeypatch, FIRST, "clientsvc/probe") == (0, "", "")
    assert store(monkeypatch, SECOND, "othersvc/probe") == (0, "", "")
    monkeypatch.setenv("SECRET_ID", FIRST)
    assert run("delete") == (0, "", "")
    assert os.listdir(folder_of(home)) == [SECOND]
    assert run("delete") == (0, "", "")
    assert os.listdir(folder_of(home)) == [SECOND]


def test_delete_succeeds_with_no_folder(home, monkeypatch):
    monkeypatch.setenv("SECRET_ID", FIRST)
    assert run("delete") == (0, "", "")
    assert os.listdir(home) == []


def test_list_prints_each_stored_id_sorted(home, monkeypatch):
    assert store(monkeypatch, SECOND, "othersvc/probe") == (0, "", "")
    assert store(monkeypatch, FIRST, "clientsvc/probe") == (0, "", "")
    folder = folder_of(home)
    (folder / "notes").write_text("not a secret\n")
    (folder / f"{FIRST}.old").write_text("clientsvc/old")
    (folder / FIRST.upper()).write_text("clientsvc/upper")
    monkeypatch.delenv("SECRET_ID")
    assert run("list") == (0, f"{FIRST}\n{SECOND}\n", "")


def test_list_prints_nothing_without_a_folder(home):
    assert run("list") == (0, "", "")


def test_list_ignores_secret_id(home, monkeypatch):
    assert store(monkeypatch, FIRST, "clientsvc/probe") == (0, "", "")
    monkeypatch.setenv("SECRET_ID", "not an id")
    assert run("list") == (0, f"{FIRST}\n", "")


def test_the_installed_program_stores_from_real_standard_input(tmp_path, home):
    env = {"SECRET_ID": FIRST}
    assert run_program(tmp_path, home, "store", data=b"clientsvc/probe", env=env) == (
        0,
        "",
        "",
    )
    assert run_program(tmp_path, home, "store", data=b"clientsvc/probe\n", env=env) == (
        1,
        "",
        SHAPE_MESSAGE,
    )
    assert (folder_of(home) / FIRST).read_bytes() == b"clientsvc/probe"
    assert run_program(tmp_path, home, "list") == (0, f"{FIRST}\n", "")


@pytest.mark.parametrize("command", ["store", "lookup", "delete", "list"])
def test_an_account_without_a_home_is_refused(home, monkeypatch, execs, command):
    def getpwuid(asked):
        raise KeyError(f"getpwuid(): uid not found: {asked}")

    monkeypatch.setattr(pwd, "getpwuid", getpwuid)
    monkeypatch.setenv("SECRET_ID", FIRST)
    feed(monkeypatch, b"clientsvc/probe")
    assert run(command) == (
        1,
        "",
        f"openbao-podman-secret: no home for uid {os.getuid()}\n",
    )


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only folder")
def test_store_reports_a_folder_it_cannot_write(home, monkeypatch):
    assert store(monkeypatch, FIRST, "clientsvc/probe") == (0, "", "")
    folder = folder_of(home)
    folder.chmod(0o500)
    try:
        assert store(monkeypatch, FIRST, "clientsvc/other") == (
            1,
            "",
            "openbao-podman-secret: store failed: Permission denied\n",
        )
    finally:
        folder.chmod(0o700)
    assert (folder / FIRST).read_bytes() == b"clientsvc/probe"


def test_store_that_fails_to_replace_leaves_no_partial_file(home, monkeypatch):
    assert store(monkeypatch, SECOND, "othersvc/probe") == (0, "", "")
    folder = folder_of(home)
    (folder / FIRST).mkdir()
    (folder / FIRST / "keep").write_text("kept")
    assert store(monkeypatch, FIRST, "clientsvc/probe") == (
        1,
        "",
        "openbao-podman-secret: store failed: Is a directory\n",
    )
    assert everything_under(folder) == [FIRST, f"{FIRST}/keep", SECOND]


@pytest.mark.parametrize("command", ["lookup", "delete"])
def test_a_read_or_removal_error_names_the_command_and_the_error(
    home, monkeypatch, execs, command
):
    folder = folder_of(home)
    (folder / FIRST).mkdir(parents=True)
    monkeypatch.setenv("SECRET_ID", FIRST)
    assert run(command) == (
        1,
        "",
        f"openbao-podman-secret: {command} failed: Is a directory\n",
    )
    assert (folder / FIRST).is_dir()


def test_list_reports_a_folder_that_is_not_a_folder(home):
    folder = folder_of(home)
    folder.parent.mkdir(parents=True)
    folder.write_text("clientsvc/probe")
    assert run("list") == (
        1,
        "",
        "openbao-podman-secret: list failed: Not a directory\n",
    )


@pytest.mark.parametrize("command", ["store", "lookup", "delete", "list"])
def test_an_unexpected_error_names_only_its_class(home, monkeypatch, execs, command):
    def getpwuid(asked):
        raise RuntimeError("clientsvc-probe")

    monkeypatch.setattr(pwd, "getpwuid", getpwuid)
    monkeypatch.setenv("SECRET_ID", FIRST)
    feed(monkeypatch, b"clientsvc/probe")
    status, output, errors = run(command)
    assert (status, output, errors) == (
        1,
        "",
        "openbao-podman-secret: unexpected error: RuntimeError\n",
    )
    assert "Traceback" not in errors
