"""Safe summaries of Gatus checks and their Prometheus readings."""

from urllib.parse import urlsplit

from ansible.errors import AnsibleFilterError


def gatus_check_summary(config):
    """Keep only the fields needed to prove certificate coverage."""
    if not isinstance(config, dict) or not isinstance(config.get("endpoints"), list):
        raise AnsibleFilterError("Gatus's configuration has no endpoints list")
    checks = []
    for endpoint in config["endpoints"]:
        url = urlsplit(endpoint["url"])
        if url.scheme in ("https", "starttls"):
            checks.append(
                {
                    "name": endpoint["name"],
                    "group": endpoint["group"],
                    "host": url.hostname,
                    "labels": endpoint.get("extra-labels") or {},
                }
            )
    return checks


def _under_domains(host, domains):
    return any(host == domain or host.endswith("." + domain) for domain in domains)


def gatus_unlabelled_hosts(checks, domains):
    hosts = {
        check["host"] for check in checks if _under_domains(check["host"], domains)
    }
    labelled = {
        check["host"]
        for check in checks
        if check["labels"].get("certificate_ticket") == "true"
    }
    return sorted(hosts - labelled)


def gatus_checks_without_reading(checks, domains, results):
    observed = {
        (result["metric"].get("group"), result["metric"].get("name"))
        for result in results
        if result["metric"].get("certificate_ticket") == "true"
    }
    return sorted(
        f"{check['group']}/{check['name']}"
        for check in checks
        if _under_domains(check["host"], domains)
        and check["labels"].get("certificate_ticket") == "true"
        and (check["group"], check["name"]) not in observed
    )


def gatus_rule_keys(rules):
    return sorted(
        {
            rule.get("annotations", {}).get("gatus_key")
            for group in rules["groups"]
            for rule in group["rules"]
            if rule.get("annotations", {}).get("gatus_key")
        }
    )


def gatus_keys_without_reading(keys, results):
    observed = {result["metric"].get("key") for result in results}
    return sorted(set(keys) - observed)


class FilterModule:
    """Expose Gatus reading checks to Ansible."""

    def filters(self):
        return {
            "gatus_check_summary": gatus_check_summary,
            "gatus_unlabelled_hosts": gatus_unlabelled_hosts,
            "gatus_checks_without_reading": gatus_checks_without_reading,
            "gatus_rule_keys": gatus_rule_keys,
            "gatus_keys_without_reading": gatus_keys_without_reading,
        }
