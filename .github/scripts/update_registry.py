#!/usr/bin/env python3
"""Adds one module version to registry/, in Bazel's custom-registry format.

Run by .github/workflows/release.yml after a <module>-vX.Y.Z tag's release
tarball is built, so registry/ always reflects exactly the versions that have
a real, downloadable release asset - never a version that doesn't exist yet.

See https://bazel.build/external/registry for the on-disk format this
produces: registry/modules/<name>/metadata.json (versions list) and
registry/modules/<name>/<version>/{MODULE.bazel,source.json}.
"""

import argparse
import base64
import hashlib
import json
import re
import sys
from pathlib import Path

MODULE_NAME_RE = re.compile(r'\bname\s*=\s*"([^"]+)"')
MODULE_VERSION_RE = re.compile(r'\bversion\s*=\s*"([^"]+)"')


def parse_module_decl(module_bazel_text: str) -> tuple[str, str]:
    # module(...) is the first call in a well-formed MODULE.bazel; take the
    # first name=/version= pair, which is enough for our own generated files
    # (we don't need a full Starlark parse here).
    match = re.search(r"module\s*\((.*?)\n\)", module_bazel_text, re.DOTALL)
    if not match:
        raise ValueError("no module(...) declaration found in MODULE.bazel")
    body = match.group(1)
    name = MODULE_NAME_RE.search(body)
    version = MODULE_VERSION_RE.search(body)
    if not name or not version:
        raise ValueError("module(...) is missing name= or version=")
    return name.group(1), version.group(1)


def sri_sha256(path: Path) -> str:
    digest = hashlib.sha256(path.read_bytes()).digest()
    return "sha256-" + base64.b64encode(digest).decode("ascii")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry-dir", required=True, type=Path)
    parser.add_argument(
        "--module-root",
        required=True,
        type=Path,
        help="path to the module's own directory (containing MODULE.bazel)",
    )
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--url", required=True, help="download URL for --archive")
    parser.add_argument(
        "--metadata-template",
        type=Path,
        help=(
            "path to .bcr/<module>/metadata.template.json, used for a new "
            "module's homepage/maintainers/repository (its own versions/"
            "yanked_versions are ignored - those are managed here instead)"
        ),
    )
    args = parser.parse_args()

    module_bazel = args.module_root / "MODULE.bazel"
    name, version = parse_module_decl(module_bazel.read_text())

    module_dir = args.registry_dir / "modules" / name
    version_dir = module_dir / version
    version_dir.mkdir(parents=True, exist_ok=True)

    (version_dir / "MODULE.bazel").write_text(module_bazel.read_text())

    source_json = {
        "url": args.url,
        "integrity": sri_sha256(args.archive),
        "strip_prefix": "",
    }
    (version_dir / "source.json").write_text(json.dumps(source_json, indent=2) + "\n")

    metadata_path = module_dir / "metadata.json"
    if metadata_path.exists():
        metadata = json.loads(metadata_path.read_text())
    elif args.metadata_template:
        template = json.loads(args.metadata_template.read_text())
        metadata = {
            "homepage": template.get("homepage", ""),
            "maintainers": template.get("maintainers", []),
            "repository": template.get("repository", []),
            "versions": [],
            "yanked_versions": {},
        }
    else:
        parser.error(
            f"{metadata_path} doesn't exist yet and no --metadata-template "
            "was given to seed it"
        )

    if version not in metadata["versions"]:
        metadata["versions"].append(version)
    metadata["versions"].sort(key=lambda v: [int(p) for p in v.split(".")])

    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")

    print(f"registry/modules/{name}/{version}: {source_json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
