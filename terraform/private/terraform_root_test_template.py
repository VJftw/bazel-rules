#!/usr/bin/env python3
"""Template for a `terraform_root_test`'s `bazel test` executable.

Expanded (via `ctx.actions.expand_template`, substituting the `%{...}%`
tokens below) by `testing.bzl` - just locates the `terraform_root`'s own
executable via runfiles and execs it with `tf_args`.
"""
import json
import os
import subprocess
import sys

RUNNER_RLOCATION = "%{runner_rlocation}%"
TF_ARGS = json.loads("""%{tf_args_json}%""")


def _rlocation(path):
    script = os.path.abspath(sys.argv[0])

    manifest = os.environ.get("RUNFILES_MANIFEST_FILE")
    if not manifest:
        for candidate in (script + ".runfiles_manifest", script + ".runfiles/MANIFEST"):
            if os.path.exists(candidate):
                manifest = candidate
                break

    if manifest:
        with open(manifest, encoding="utf-8") as f:
            for line in f:
                link, _, target = line.rstrip("\n").partition(" ")
                if link == path:
                    return target
        sys.exit("ERROR: %s not found in runfiles manifest %s" % (path, manifest))

    runfiles_dir = os.environ.get("RUNFILES_DIR")
    if not runfiles_dir and os.path.isdir(script + ".runfiles"):
        runfiles_dir = script + ".runfiles"
    if runfiles_dir:
        return os.path.join(runfiles_dir, path)

    sys.exit("ERROR: cannot find runfiles (no RUNFILES_DIR/RUNFILES_MANIFEST_FILE, run via `bazel test`)")


def main():
    runner = _rlocation(RUNNER_RLOCATION)
    # subprocess (not os.execv) - on Windows, `runner` may be a `.bat`
    # launcher, which os.execv can't invoke directly (it isn't a real PE
    # executable; only cmd.exe knows how to run it).
    result = subprocess.run([runner] + TF_ARGS)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
