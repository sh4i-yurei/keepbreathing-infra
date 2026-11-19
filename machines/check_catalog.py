"""Check the machine catalog's structure and class references."""

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator


SCHEMA = Path(__file__).with_name("catalog.schema.json")


def main(argv):
    if len(argv) != 1:
        print("usage: check_catalog.py <file>", file=sys.stderr)
        return 2

    filename = argv[0]
    try:
        catalog = json.loads(Path(filename).read_bytes())
    except (OSError, ValueError) as error:
        print(f"{filename}: {error}", file=sys.stderr)
        return 1

    schema = json.loads(SCHEMA.read_bytes())
    validator = Draft202012Validator(schema)
    problems = sorted(
        f"{'/'.join(map(str, error.absolute_path)) or '(top)'} | {error.message}"
        for error in validator.iter_errors(catalog)
    )
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1

    ocean = catalog["digitalocean"]
    classes = ocean["classes"]
    if ocean["bake_class"] not in classes:
        problems.append(
            f"digitalocean/bake_class | {ocean['bake_class']!r} is not a class"
        )
    for machine, details in ocean["machines"].items():
        if details["class"] not in classes:
            problems.append(
                f"digitalocean/machines/{machine}/class | {details['class']!r} is not a class"
            )
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1

    print(f"{filename}: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
