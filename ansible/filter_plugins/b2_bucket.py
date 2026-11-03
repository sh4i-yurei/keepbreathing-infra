"""Pure planning interface for B2 bucket reconciliation."""


def b2_lifecycle_rules_match(rules, hidden_days):
    if not isinstance(rules, list) or len(rules) != 1:
        return False
    rule = rules[0]
    if not isinstance(rule, dict):
        return False
    required = {"daysFromHidingToDeleting", "fileNamePrefix"}
    optional = {
        "daysFromStartingToCancelingUnfinishedLargeFiles",
        "daysFromUploadingToHiding",
    }
    if not required <= rule.keys() or not rule.keys() <= required | optional:
        return False
    return (
        rule["daysFromHidingToDeleting"] == hidden_days
        and rule["fileNamePrefix"] == ""
        and all(rule.get(field) is None for field in optional)
    )


def b2_bucket_plan(current, retention_days, hidden_days):
    if current is None:
        return {"create": True, "update": False}
    retention = {
        "mode": "compliance",
        "period": {"duration": retention_days, "unit": "days"},
    }
    lock = current.get("fileLockConfiguration", {}).get("value") or {}
    update = (
        current.get("bucketType") != "allPrivate"
        or lock.get("isFileLockEnabled") != True
        or lock.get("defaultRetention") != retention
        or not b2_lifecycle_rules_match(current.get("lifecycleRules"), hidden_days)
    )
    return {"create": False, "update": update}


class FilterModule:
    def filters(self):
        return {
            "b2_bucket_plan": b2_bucket_plan,
            "b2_lifecycle_rules_match": b2_lifecycle_rules_match,
        }
