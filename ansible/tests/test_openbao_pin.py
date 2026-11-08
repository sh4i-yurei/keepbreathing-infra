"""OpenBao's image pin has one home, group_vars/all.yml (Backups decisions 72 and 73)."""

from pathlib import Path
import re

import yaml


ANSIBLE = Path(__file__).resolve().parents[1]
GROUP_VARS = ANSIBLE / "group_vars" / "all.yml"
PINNED_IMAGE = re.compile(r"[^@\s]+@(sha256:[0-9a-f]{64})")


def files_containing(text):
    found = []
    for path in sorted(ANSIBLE.rglob("*")):
        if not path.is_file():
            continue
        try:
            content = path.read_bytes().decode("utf-8")
        except UnicodeDecodeError:
            continue
        if text in content:
            found.append(path.relative_to(ANSIBLE).as_posix())
    return found


def test_openbao_image_digest_lives_only_in_group_vars():
    group_vars = yaml.safe_load(GROUP_VARS.read_text())
    assert "openbao_image" in group_vars, "group_vars/all.yml must hold openbao_image"
    pinned = PINNED_IMAGE.fullmatch(group_vars["openbao_image"])
    assert pinned, (
        f"openbao_image must be pinned by digest: {group_vars['openbao_image']}"
    )
    digest = pinned.group(1)

    holders = files_containing(digest)
    others = [name for name in holders if name != "group_vars/all.yml"]
    assert not others, (
        f"{digest} must appear only in group_vars/all.yml, also in: {others}"
    )
    assert holders == ["group_vars/all.yml"]
