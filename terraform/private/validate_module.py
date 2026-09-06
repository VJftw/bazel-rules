"""Runs `terraform init && terraform validate` against a staged module tree.

Invoked as a build action (via the hermetic Python toolchain, not a shell) -
see `validate_action` in private/common.bzl. All paths are plain,
already execroot-relative paths; no runfiles resolution is needed here
(unlike private/terraform_runner.py, which runs later, outside the build
sandbox).

TF_DATA_DIR is a plain scratch directory (not a declared Bazel output) -
Terraform's filesystem-mirror provider install symlinks straight into it
from the mirror's own input files, and a declared tree-artifact output
can't contain symlinks pointing outside itself (Bazel rejects them as
"dangling" once the action's sandbox is torn down). Only the `.validated`
marker file is an actual tracked output; this directory's lifetime is the
same as any other action-local scratch space.
"""

import argparse
import json
import os
import subprocess
import tempfile

FILESYSTEM_MIRROR_BLOCK = """
  filesystem_mirror {{
    path    = "{mirror_root}"
    include = ["*/*/*"]
  }}"""

# One `filesystem_mirror` block per independent mirror root (the
# toolchain-fetched mirror, plus one per `terraform_local_provider` - see
# `collect_provider_mirror_sources` in private/common.bzl), each `include`d
# unconditionally since every root only ever holds the providers it was
# actually given. `direct` is excluded unconditionally too (rather than just
# excluding a specific hostname) - a provider that isn't in any mirror should
# fail loudly (no filesystem mirror package found), not silently reach out
# to the network (which the build/test sandbox blocks anyway).
PROVIDER_CLI_CONFIG = """
disable_checkpoint = true

provider_installation {{
{filesystem_mirror_blocks}
  direct {{
    exclude = ["*/*/*"]
  }}
}}
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--terraform-bin", required=True)
    parser.add_argument("--module-dir", required=True)
    parser.add_argument("--marker", required=True, help="Output file to create on success.")
    parser.add_argument("--manifest-seed", default="", help="Pre-built modules.json to seed into --data-dir/modules/, if any.")
    parser.add_argument(
        "--provider-mirror-root",
        action="append",
        default=[],
        dest="provider_mirror_roots",
        help="Execroot-relative path to a provider filesystem mirror root; repeatable, one per independent mirror source.",
    )
    args = parser.parse_args()

    # `-chdir` changes the process's cwd before Terraform resolves TF_DATA_DIR
    # or anything inside the pre-fab manifest, so a *relative* TF_DATA_DIR (or
    # a relative "Dir" entry within modules.json) would then be resolved
    # relative to the wrong (post-chdir) directory. Absolute-ify everything
    # up front instead, same as the (now-removed) bash version's "$ROOT/"
    # prefixing.
    cwd = os.getcwd()
    terraform_bin = os.path.abspath(args.terraform_bin)
    module_dir = os.path.abspath(args.module_dir)
    data_dir = tempfile.mkdtemp()

    env = dict(os.environ)
    env["TF_DATA_DIR"] = data_dir
    if args.provider_mirror_roots:
        blocks = "\n".join(
            FILESYSTEM_MIRROR_BLOCK.format(mirror_root=os.path.abspath(root))
            for root in args.provider_mirror_roots
        )
        cli_config_path = os.path.join(data_dir, ".terraformrc")
        with open(cli_config_path, "w", encoding="utf-8") as f:
            f.write(PROVIDER_CLI_CONFIG.format(filesystem_mirror_blocks=blocks))
        env["TF_CLI_CONFIG_FILE"] = cli_config_path

    if args.manifest_seed:
        with open(args.manifest_seed, encoding="utf-8") as f:
            manifest = json.load(f)
        for entry in manifest.get("Modules", []):
            d = entry.get("Dir")
            if d and not os.path.isabs(d):
                entry["Dir"] = os.path.join(cwd, d)
        modules_dir = os.path.join(data_dir, "modules")
        os.makedirs(modules_dir, exist_ok=True)
        with open(os.path.join(modules_dir, "modules.json"), "w", encoding="utf-8") as f:
            json.dump(manifest, f)

    chdir = "-chdir=" + module_dir
    subprocess.run([terraform_bin, chdir, "init", "-input=false", "-backend=false", "-no-color"], env=env, check=True)
    subprocess.run([terraform_bin, chdir, "validate", "-no-color"], env=env, check=True)

    with open(args.marker, "w", encoding="utf-8"):
        pass


if __name__ == "__main__":
    main()
