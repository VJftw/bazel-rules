"""Copies a `terraform_module`'s transitive srcs + registry files into one tree.

Invoked as a build action (via the hermetic Python toolchain, not a shell) -
see `stage_module` in private/common.bzl. All paths are plain, already
execroot-relative paths; no runfiles resolution is needed here (unlike
private/terraform_runner.py, which runs later, outside the build sandbox).
"""

import argparse
import json
import os
import shutil


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, help="JSON file: list of [src, dest] pairs, dest relative to --out.")
    parser.add_argument("--out", required=True, help="Output directory (a declare_directory tree artifact).")
    args = parser.parse_args()

    with open(args.manifest, encoding="utf-8") as f:
        pairs = json.load(f)

    for src, dest in pairs:
        full_dest = os.path.join(args.out, dest)
        os.makedirs(os.path.dirname(full_dest), exist_ok=True)
        shutil.copyfile(src, full_dest)


if __name__ == "__main__":
    main()
