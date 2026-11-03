"""Pure planning interface for B2 bucket reconciliation."""


def b2_bucket_plan(current, retention_days, hidden_days):
    if current is None:
        return {"create": True, "update": False}
    retention = {
        "mode": "compliance",
        "period": {"duration": retention_days, "unit": "days"},
    }
    lifecycle = [
        {
            "daysFromHidingToDeleting": hidden_days,
            "daysFromUploadingToHiding": None,
            "fileNamePrefix": "",
        }
    ]
    lock = current.get("fileLockConfiguration", {}).get("value") or {}
    update = (
        current.get("bucketType") != "allPrivate"
        or lock.get("isFileLockEnabled") != True
        or lock.get("defaultRetention") != retention
        or current.get("lifecycleRules") != lifecycle
    )
    return {"create": False, "update": update}


class FilterModule:
    def filters(self):
        return {"b2_bucket_plan": b2_bucket_plan}
