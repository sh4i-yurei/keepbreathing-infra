"""The map cases every program that finds its account through /proc/self/uid_map must pass.

Podman runs a secret driver's commands, and podman unshare, inside the account's rootless user
namespace, where the account is uid 0 and the namespace's uid map names its real uid (OpenBao on
the hub decision 63). Each case is the process's own uid, the exact text of its uid map, or None
for a missing file, and the outcome: the account's uid, or the one failure line, with {program}
standing for the program's name. The kernel pads each field with spaces.
"""

from typing import NamedTuple

NOT_ROOT = "{program}: will not run as root"
NO_MAP = "{program}: could not read this namespace's uid map"


class MapCase(NamedTuple):
    name: str
    uid: int
    uid_map: str | None
    outcome: int | str


CASES = [
    # Podman's namespace: the line for 0 comes after another line, and before a subuid range.
    MapCase(
        "podman namespace",
        0,
        "      1000          0          1\n"
        "         0       1002          1\n"
        "         1     524288      65536\n",
        1002,
    ),
    # Any uid but 0 is the account's own, whatever the map would make of it.
    MapCase("not uid 0", 1, "         1       9999          1\n", 1),
    # Root on the hub and on GitHub's runner, where the map is the identity.
    MapCase("identity map", 0, "         0          0 4294967295\n", NOT_ROOT),
    MapCase("missing map", 0, None, NO_MAP),
    MapCase("no line for 0", 0, "         1       1002          1\n", NO_MAP),
    # A line for 0 without exactly three fields doesn't count.
    MapCase("short line for 0", 0, "         0       1002\n", NO_MAP),
]
