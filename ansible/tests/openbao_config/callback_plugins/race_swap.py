"""Swap one part of a consumer folder's path for a link, right after the role has listed folders.

The openbao_config driver enables this callback for the plays that rehearse an account swapping a
link into its path between the role's find and its removal. Ansible's linear strategy runs this
callback before the next task starts, so the swap always lands in that gap. RACE_SWAP names the
path to swap, and RACE_TARGET the folder outside /home that the link points at. The original is
kept beside it as RACE_SWAP.moved, for the driver to put back.
"""

import os

from ansible.plugins.callback import CallbackBase

FIND_TASK = "OpenBao config | List the consumer folders on the machine"


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "race_swap"
    CALLBACK_NEEDS_ENABLED = True

    def v2_runner_on_ok(self, result):
        if result.task.name != FIND_TASK:
            return
        swap, target = os.environ["RACE_SWAP"], os.environ["RACE_TARGET"]
        if os.path.islink(swap):
            return
        os.rename(swap, swap + ".moved")
        os.symlink(target, swap)
