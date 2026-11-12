"""The JWT roles Infrastructure as code's GitHub jobs sign in as on the hub (OpenBao on the hub decisions 65 and 71)."""

from pathlib import Path

import yaml


ANSIBLE = Path(__file__).resolve().parents[1]
REPOSITORY_ID = "1368108961"
SITE_REPOSITORY_ID = "1305427147"
SHORT_LIVED_WORKFLOW = (
    "sh4i-yurei/keepbreathing-infra/.github/workflows/short-lived.yml@refs/heads/main"
)


def read(path):
    return yaml.safe_load((ANSIBLE / path).read_text())


def jwt_roles():
    return read("host_vars/hub.yml")["openbao_jwt_roles"]


def jwt_role(name):
    matches = [role for role in jwt_roles() if role["name"] == name]
    assert matches, f"no {name} in openbao_jwt_roles"
    assert len(matches) == 1, f"{name} is listed {len(matches)} times"
    return matches[0]


def test_the_hub_lists_exactly_the_three_jwt_roles_in_order():
    names = [role["name"] for role in jwt_roles()]
    assert "iac-durable" in names, "no iac-durable in openbao_jwt_roles"
    assert names == ["iac-plan", "iac-durable", "iac-short-lived"]


def test_iac_durable_binds_the_repository_and_the_durable_environment():
    role = jwt_role("iac-durable")
    assert role == {
        "name": "iac-durable",
        "bound_claims": {"repository_id": REPOSITORY_ID, "environment": "durable"},
        "transit_keys": ["tofu-durable"],
        "extra_paths": [
            {
                "path": "secret/data/iac-short-lived/+/access-service-token",
                "capabilities": ["create", "update", "delete"],
            },
            {
                "path": "secret/data/iac-short-lived/+/access-service-token-id",
                "capabilities": ["create", "update", "delete"],
            },
        ],
    }
    assert all(isinstance(value, str) for value in role["bound_claims"].values())


def test_iac_plan_and_iac_short_lived_keep_their_bindings():
    assert jwt_role("iac-plan") == {
        "name": "iac-plan",
        "bound_claims": {"repository_id": REPOSITORY_ID},
        "transit_keys": ["tofu-durable"],
    }
    assert jwt_role("iac-short-lived") == {
        "name": "iac-short-lived",
        "bound_claims": {
            "repository_id": SITE_REPOSITORY_ID,
            "job_workflow_ref": SHORT_LIVED_WORKFLOW,
        },
        "transit_keys": ["tofu-short-lived"],
    }
