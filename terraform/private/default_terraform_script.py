#!/usr/bin/env python3
"""`terraform_root`'s built-in default `script` (see extensions.bzl/root.bzl).

Every `terraform_root` hands off to *some* script - this is the one used
when neither the target nor `terraform.default_script` names another one, so
`bazel run //path:name -- plan` behaves like running `terraform` directly:
auto-`init` before any subcommand that needs an initialized working
directory, then exec the real command.

Runs as a plain script, same as terraform_runner_template.py, which already
resolved TF_BIN/TF_MODULE_DIR and chdir'd into the module dir before handing
off here - no runfiles lookup, and no `-chdir=...` flag, needed.
"""
import os
import subprocess
import sys

AUTO_INIT_COMMANDS = {"plan", "apply", "destroy", "validate", "refresh", "import", "console", "output"}


def main():
    tf_bin = os.environ["TF_BIN"]
    args = sys.argv[1:]

    if args and args[0] in AUTO_INIT_COMMANDS:
        subprocess.run([tf_bin, "init", "-input=false", "-no-color"], check=True)

    os.execv(tf_bin, [tf_bin] + args)


if __name__ == "__main__":
    main()
