"""Check that the fail2ban drop-in can override the packaged log target."""

from configparser import ConfigParser
from pathlib import Path


def test_fail2ban_journal_drop_in_overrides_package_default() -> None:
    drop_in = Path(__file__).parents[1] / "roles/baseline/files/fail2ban-journal.local"
    config = ConfigParser()
    config.read_string("[DEFAULT]\nlogtarget = /var/log/fail2ban.log\n")
    assert config.read(drop_in) == [str(drop_in)]
    assert config.defaults()["logtarget"] == "SYSTEMD-JOURNAL"
