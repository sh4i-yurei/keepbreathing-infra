#!/usr/bin/python3
"""Report enabled DNF repositories whose effective gpgcheck setting is false."""

import argparse
import sys


def arguments() -> argparse.Namespace:
    """Read optional paths used by the fixture tests."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", help="read this DNF configuration file")
    parser.add_argument("--reposdir", help="read repository files from this directory")
    return parser.parse_args()


def main() -> int:
    """Ask DNF for effective enabled-repository settings and report unsafe ones."""
    args = arguments()
    try:
        import dnf

        base = dnf.Base()
        if args.config:
            base.conf.config_file_path = args.config
        base.conf.read()
        if args.reposdir:
            base.conf.reposdir = [args.reposdir]
        base.read_all_repos()
        unsafe_repositories = sorted(
            repository.id
            for repository in base.repos.iter_enabled()
            if not repository.gpgcheck
        )
    # DNF can raise backend-specific exceptions which differ between its versions.
    except Exception as error:  # noqa: BLE001
        print(f"Could not read effective DNF repository settings: {error}")
        return 2

    for repository_id in unsafe_repositories:
        print(repository_id)
    return 1 if unsafe_repositories else 0


if __name__ == "__main__":
    sys.exit(main())
