#!/usr/bin/env python3
"""Manages registry/, this repo's self-hosted Bazel module registry.

Every change to a module's released contents comes with a new version, and
that version's registry entry, in the same pull request - so registry/ on
main only ever changes through reviewed pull requests, and nothing ever has
to push to main directly. The entry's integrity hash is of the module's
release archive, which is built reproducibly (see `build_archive`), so it
can be computed before the archive is actually published: `release.yml`
rebuilds the exact same archive after the pull request merges, checks it
against the entry, and only then publishes it as a GitHub Release.

The new version follows from the pull request's title, which must be a
Conventional Commit (https://www.conventionalcommits.org/) - with squash
merges, it's the commit message that actually lands on main. It applies to
every module the pull request changes:

  feat(...)!: / fix!: / ...  breaking - a major bump (a minor one while the
                             module's still 0.x, as 0.x makes no
                             compatibility promises)
  feat(...): ...             a minor bump
  fix(...): ... (or any      a patch bump - the module's released contents
  other type)                still changed

Subcommands:

  bump [--title TITLE] [--base REF]
                    Run in your pull request, after staging your changes:
                    for every module whose released contents changed since
                    REF (default: origin/main, or else main), sets `module(version = ...)` in its MODULE.bazel to
                    the version TITLE implies, writes its registry entry, and
                    stages both. TITLE defaults to the open pull request's
                    title (via `gh`), or else the branch's only commit's
                    subject. Safe to re-run - e.g. after more changes, or a
                    new title - and it replaces the registry entries it
                    wrote before.

  check --title TITLE --base REF
                    What CI runs on every pull request: TITLE must be a
                    Conventional Commit, and every module whose released
                    contents changed since REF must have the version it
                    implies and an up-to-date registry entry for it.

  add <module>      Writes and stages the registry entry for <module>'s
                    current version, as-is (`bump` does this for you).

  releasable        Lists `<module> <tag>` for every module whose current
                    version has a registry entry - used by release.yml, which
                    releases the ones that aren't released yet.

  archive <module> --out PATH [--verify]
                    Builds <module>'s release archive - used by release.yml.
                    With --verify, fails unless it matches the registry
                    entry for <module>'s current version.

See https://bazel.build/external/registry for the registry's on-disk format:
registry/modules/<name>/metadata.json (versions list) and
registry/modules/<name>/<version>/{MODULE.bazel,source.json}.
"""

import argparse
import base64
import fnmatch
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

REGISTRY_DIR = Path("registry")

# Paths (relative to a module's own directory) whose changes don't need a new
# version: the examples/ module (its own test suite, not something a consumer
# loads), documentation, and Bazel's own lockfile. They're still part of the
# release archive (BCR's presubmit runs examples/ from it).
EXEMPT_PATTERNS = [
    "examples/*",
    "*.md",
    "MODULE.bazel.lock",
]

# https://www.conventionalcommits.org/ - the types are @commitlint/config-conventional's.
CONVENTIONAL_TYPES = ["build", "chore", "ci", "docs", "feat", "fix", "perf", "refactor", "revert", "style", "test"]
CONVENTIONAL_RE = re.compile(r"^(?P<type>[a-z]+)(?:\([^()]+\))?(?P<breaking>!)?: \S")

MODULE_DECL_RE = re.compile(r"module\s*\((.*?)\n\)", re.DOTALL)
MODULE_NAME_RE = re.compile(r'\bname\s*=\s*"([^"]+)"')
MODULE_VERSION_RE = re.compile(r'\bversion\s*=\s*"([^"]+)"')


class Error(Exception):
    pass


def git(*args: str, input: bytes | None = None) -> bytes:
    return subprocess.run(["git", *args], check=True, capture_output=True, input=input).stdout


def git_show(spec: str) -> str | None:
    """A file's content at `spec` (e.g. `<ref>:<path>`, or `:<path>` for the index), or None if it doesn't exist."""
    result = subprocess.run(["git", "show", spec], capture_output=True)
    return result.stdout.decode() if result.returncode == 0 else None


# --- Modules and versions ----------------------------------------------------


def parse_module_decl(module_bazel_text: str) -> tuple[str, str]:
    # module(...) is the first call in a well-formed MODULE.bazel; take the
    # first name=/version= pair, which is enough for this repo's own modules
    # (no need for a full Starlark parse here).
    match = MODULE_DECL_RE.search(module_bazel_text)
    if not match:
        raise Error("no module(...) declaration found in MODULE.bazel")
    body = match.group(1)
    name = MODULE_NAME_RE.search(body)
    version = MODULE_VERSION_RE.search(body)
    if not name or not version:
        raise Error("module(...) is missing name= or version=")
    return name.group(1), version.group(1)


def set_module_version(module_bazel_text: str, version: str) -> str:
    """`module_bazel_text` with its module(...)'s own version - and nothing else, e.g. a bazel_dep's - set."""
    match = MODULE_DECL_RE.search(module_bazel_text)
    body = MODULE_VERSION_RE.sub(f'version = "{version}"', match.group(1), count=1)
    return module_bazel_text[: match.start(1)] + body + module_bazel_text[match.end(1) :]


def version_key(version: str) -> list[int]:
    try:
        parts = [int(part) for part in version.split(".")]
    except ValueError:
        parts = []
    if len(parts) != 3:
        raise Error(f"version {version!r} isn't a plain MAJOR.MINOR.PATCH version")
    return parts


def bump_level(title: str) -> str:
    """"major", "minor" or "patch", from a Conventional Commit `title`."""
    match = CONVENTIONAL_RE.match(title)
    if not match or match.group("type") not in CONVENTIONAL_TYPES:
        raise Error(
            f"{title!r} isn't a Conventional Commit - it should look like `<type>(<optional scope>): <description>`, "
            f"with `!` before the `:` for a breaking change, where <type> is one of: {', '.join(CONVENTIONAL_TYPES)}. "
            "See https://www.conventionalcommits.org/"
        )
    if match.group("breaking"):
        return "major"
    return "minor" if match.group("type") == "feat" else "patch"


def bumped(version: str, level: str) -> str:
    major, minor, patch = version_key(version)
    if level == "major" and major > 0:
        return f"{major + 1}.0.0"
    if level in ("major", "minor"):  # A breaking change while 0.x is a minor bump.
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def module_dirs() -> list[str]:
    """Every module in this repo: a top-level directory with a MODULE.bazel staged in git."""
    paths = git("ls-files", "-z", "--", "*/MODULE.bazel").decode().split("\0")
    return sorted({p.split("/")[0] for p in paths if p.count("/") == 1})


def is_exempt(relpath: str) -> bool:
    return any(fnmatch.fnmatch(relpath, pattern) for pattern in EXEMPT_PATTERNS)


def changed_modules(merge_base: str) -> dict[str, list[str]]:
    """{module: its staged files, other than EXEMPT_PATTERNS, that differ from `merge_base`}.

    A MODULE.bazel that only differs in its own version doesn't count - so a
    version `bump` set doesn't make a module count as changed by itself.
    """
    changed = git("diff", "--cached", "--name-only", merge_base).decode().splitlines()
    modules = {}
    for module in module_dirs():
        prefix = module + "/"
        files = [path for path in changed if path.startswith(prefix) and not is_exempt(path[len(prefix) :])]
        module_bazel = f"{module}/MODULE.bazel"
        if module_bazel in files:
            base_text = git_show(f"{merge_base}:{module_bazel}")
            if base_text is not None:
                base_version = parse_module_decl(base_text)[1]
                if set_module_version(staged_module_bazel(module), base_version) == base_text:
                    files.remove(module_bazel)
        if files:
            modules[module] = files
    return modules


def resolve_merge_base(base: str) -> str:
    try:
        return git("merge-base", base, "HEAD").decode().strip()
    except subprocess.CalledProcessError:
        raise Error(f"can't find where this branch diverged from {base!r} - is it fetched?")


# --- The release archive -----------------------------------------------------


def staged_files(module: str) -> list[tuple[str, str, bytes]]:
    """(path relative to `module`, git mode, content) for every staged file in `module`."""
    entries = []
    for line in git("ls-files", "--stage", "-z", "--", module).split(b"\0"):
        if not line:
            continue
        meta, path = line.decode().split("\t", 1)
        mode, blob, stage = meta.split()
        if stage != "0":
            raise Error(f"{path} has unresolved merge conflicts")
        entries.append((path, mode, blob))

    blobs = git("cat-file", "--batch", input=b"".join(blob.encode() + b"\n" for _, _, blob in entries))
    files = []
    offset = 0
    for path, mode, blob in entries:
        header_end = blobs.index(b"\n", offset)
        size = int(blobs[offset:header_end].split()[2])
        content = blobs[header_end + 1 : header_end + 1 + size]
        offset = header_end + 1 + size + 1  # The content is followed by a newline.
        files.append((path[len(module) + 1 :], mode, content))
    return files


def build_archive(module: str) -> bytes:
    """Builds `module`'s release archive from what's staged in git.

    Reproducible - the same staged content always gives byte-for-byte the
    same archive, on any machine - so its hash can be put in the registry
    before it's published:

    - Staged content (not the working tree), so untracked/ignored files (e.g.
      `bazel-*` symlinks) can't leak in, and a pull request's CI and the
      release after it see exactly the same files.
    - Sorted entries, with fixed ownership, timestamps and permissions (only
      git's own executable bit carries over).
    - An uncompressed .tar, since compressors (e.g. zlib vs zlib-ng) can
      produce different bytes for the same input.

    Its root is the module's own contents (no wrapper directory).
    """
    files = staged_files(module)
    if not files:
        raise Error(f"no files from {module}/ are staged in git - `git add` them first")

    dirs = set()
    for path, _, _ in files:
        parts = path.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]))

    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w", format=tarfile.USTAR_FORMAT) as tar:

        def info(name: str, type: bytes, mode: int, size: int = 0) -> tarfile.TarInfo:
            ti = tarfile.TarInfo(name)
            ti.type = type
            ti.mode = mode
            ti.size = size
            ti.mtime = 0
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            return ti

        entries = [(d + "/", None, None) for d in dirs] + files
        for path, mode, content in sorted(entries, key=lambda e: e[0]):
            if mode is None:
                tar.addfile(info(path.rstrip("/"), tarfile.DIRTYPE, 0o755))
            elif mode == "120000":
                ti = info(path, tarfile.SYMTYPE, 0o777)
                ti.linkname = content.decode()
                tar.addfile(ti)
            else:
                executable = mode == "100755"
                tar.addfile(info(path, tarfile.REGTYPE, 0o755 if executable else 0o644, len(content)), io.BytesIO(content))
    return out.getvalue()


def sri_sha256(data: bytes) -> str:
    return "sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode("ascii")


def release_tag(module: str, version: str) -> str:
    return f"{module}-v{version}"


def archive_name(module: str, version: str) -> str:
    return f"rules_{module}-{release_tag(module, version)}.tar"


def github_repository(module: str) -> str:
    """`owner/repo`, from .bcr/<module>/metadata.template.json's `repository`."""
    template = json.loads(Path(".bcr", module, "metadata.template.json").read_text())
    for repository in template.get("repository", []):
        if repository.startswith("github:"):
            return repository[len("github:") :]
    raise Error(f".bcr/{module}/metadata.template.json has no github: repository")


def release_url(module: str, version: str) -> str:
    tag = release_tag(module, version)
    return f"https://github.com/{github_repository(module)}/releases/download/{tag}/{archive_name(module, version)}"


# --- Registry entries --------------------------------------------------------


def staged_module_bazel(module: str) -> str:
    text = git_show(f":{module}/MODULE.bazel")
    if text is None:
        raise Error(f"{module}/MODULE.bazel isn't staged in git - `git add` it first")
    return text


def expected_entry(module: str) -> tuple[str, str, dict, str]:
    """(name, version, source.json, MODULE.bazel) the registry should have for `module`'s staged state."""
    module_bazel = staged_module_bazel(module)
    name, version = parse_module_decl(module_bazel)
    source = {
        "url": release_url(module, version),
        "integrity": sri_sha256(build_archive(module)),
        "strip_prefix": "",
    }
    return name, version, source, module_bazel


def metadata_path(name: str) -> Path:
    return REGISTRY_DIR / "modules" / name / "metadata.json"


def registry_versions(name: str, ref: str = "") -> list[str]:
    """`name`'s versions in registry/ at `ref` ("" for the index)."""
    text = git_show(f"{ref}:{metadata_path(name)}")
    return json.loads(text)["versions"] if text else []


def load_metadata(module: str, name: str) -> dict:
    path = metadata_path(name)
    if path.exists():
        return json.loads(path.read_text())
    template = json.loads(Path(".bcr", module, "metadata.template.json").read_text())
    return {
        "homepage": template.get("homepage", ""),
        "maintainers": template.get("maintainers", []),
        "repository": template.get("repository", []),
        "versions": [],
        "yanked_versions": {},
    }


def write_metadata(name: str, metadata: dict) -> None:
    metadata["versions"].sort(key=version_key)
    metadata_path(name).write_text(json.dumps(metadata, indent=2) + "\n")


def add(module: str) -> None:
    """Writes and stages the registry entry for `module`'s staged state."""
    name, version, source, module_bazel = expected_entry(module)
    version_dir = REGISTRY_DIR / "modules" / name / version
    version_dir.mkdir(parents=True, exist_ok=True)
    (version_dir / "MODULE.bazel").write_text(module_bazel)
    (version_dir / "source.json").write_text(json.dumps(source, indent=2) + "\n")

    metadata = load_metadata(module, name)
    if version not in metadata["versions"]:
        metadata["versions"].append(version)
    write_metadata(name, metadata)

    git("add", "--", str(version_dir), str(metadata_path(name)))
    print(f"{module}: wrote and staged {version_dir}/ ({source['integrity']})")


def remove_unreleased(module: str, name: str, merge_base: str, keep: str | None) -> None:
    """Removes (and stages removing) `name`'s registry entries that this branch added, other than `keep`."""
    released = set(registry_versions(name, merge_base))
    stale = [v for v in registry_versions(name) if v not in released and v != keep]
    if not stale:
        return
    metadata = load_metadata(module, name)
    metadata["versions"] = [v for v in metadata["versions"] if v not in stale]
    for version in stale:
        version_dir = REGISTRY_DIR / "modules" / name / version
        shutil.rmtree(version_dir, ignore_errors=True)
        git("rm", "-r", "--cached", "--quiet", "--ignore-unmatch", "--", str(version_dir))
        print(f"{module}: removed {version_dir}/, which this branch added before")
    if metadata["versions"]:
        write_metadata(name, metadata)
        git("add", "--", str(metadata_path(name)))
    else:
        shutil.rmtree(metadata_path(name).parent, ignore_errors=True)
        git("rm", "-r", "--cached", "--quiet", "--ignore-unmatch", "--", str(metadata_path(name).parent))


def default_title(merge_base: str) -> str:
    """The open pull request's title (via `gh`), or else the branch's only commit's subject."""
    if shutil.which("gh"):
        result = subprocess.run(["gh", "pr", "view", "--json", "title", "--jq", ".title"], capture_output=True)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.decode().strip()
    subjects = git("log", "--format=%s", f"{merge_base}..HEAD").decode().splitlines()
    if len(subjects) == 1:
        return subjects[0]
    raise Error(
        "can't tell what the pull request's title will be (there's no open pull request for this branch, and it "
        f"has {len(subjects)} commits) - pass it with --title, e.g. --title 'feat(opa): add opa_fmt_test'"
    )


def set_version(module: str, version: str) -> None:
    """Sets (and stages) `module`'s own version in its MODULE.bazel."""
    path = Path(module, "MODULE.bazel")
    path.write_text(set_module_version(path.read_text(), version))
    git("add", "--", str(path))


def bump(base: str | None, title: str | None) -> None:
    if base is None:
        has_origin_main = subprocess.run(["git", "rev-parse", "--verify", "--quiet", "origin/main"], capture_output=True)
        base = "origin/main" if has_origin_main.returncode == 0 else "main"
    merge_base = resolve_merge_base(base)
    title = title or default_title(merge_base)
    level = bump_level(title)
    changed = changed_modules(merge_base)
    print(f"{title!r}: a {level} bump for every changed module")

    for module in module_dirs():
        module_bazel = staged_module_bazel(module)
        name, version = parse_module_decl(module_bazel)
        base_module_bazel = git_show(f"{merge_base}:{module}/MODULE.bazel")
        if module not in changed:
            remove_unreleased(module, name, merge_base, keep=None)
            if base_module_bazel is not None:
                base_version = parse_module_decl(base_module_bazel)[1]
                if version != base_version:
                    set_version(module, base_version)
                    print(f"{module}: unchanged, so restored its version to {base_version}")
            continue

        unstaged = git("diff", "--name-only", "--", module).decode().split()
        if unstaged:
            print(f"{module}: warning: ignoring unstaged changes (`git add` them and re-run): {', '.join(unstaged)}")

        if base_module_bazel is None:
            print(f"{module}: a new module, keeping its version {version}")
        else:
            base_version = parse_module_decl(base_module_bazel)[1]
            version = bumped(base_version, level)
            set_version(module, version)
            print(f"{module}: version {base_version} -> {version}")

        remove_unreleased(module, name, merge_base, keep=version)
        add(module)


def check(base: str, title: str) -> list[str]:
    merge_base = resolve_merge_base(base)
    changed = changed_modules(merge_base)
    fix = "run `.github/scripts/registry.py bump` (after staging your changes) and commit the result"

    errors = []
    level = None
    if changed:
        try:
            level = bump_level(title)
        except Error as e:
            errors.append(f"the pull request's title: {e}")

    for module in module_dirs():
        name, version = parse_module_decl(staged_module_bazel(module))
        released = registry_versions(name, merge_base)
        added = [v for v in registry_versions(name) if v not in released]

        if module not in changed:
            base_module_bazel = git_show(f"{merge_base}:{module}/MODULE.bazel")
            if base_module_bazel is not None and parse_module_decl(base_module_bazel)[1] != version:
                errors.append(f"{module}: {name}'s version changed, but nothing else about it did - {fix}")
            if added:
                errors.append(f"{module}: {name} hasn't changed, but registry/ has new versions of it ({', '.join(added)}) - {fix}")
            continue

        files = "\n  ".join(changed[module])
        base_module_bazel = git_show(f"{merge_base}:{module}/MODULE.bazel")
        base_version = parse_module_decl(base_module_bazel)[1] if base_module_bazel else None
        print(f"{module} ({name}): {len(changed[module])} file(s) changed, version {base_version} -> {version}")

        if version in released:
            errors.append(f"{module}: version {version} of {name} is already released - {fix}, since these files changed:\n  {files}")
            continue
        if base_version and level:
            expected = bumped(base_version, level)
            if version != expected:
                errors.append(
                    f"{module}: {name} should be version {expected} - a {level} bump from {base_version}, for the "
                    f"pull request's title {title!r} - not {version}; {fix}"
                )
                continue
        if [v for v in added if v != version]:
            errors.append(f"{module}: registry/ has new versions of {name} other than {version}: {', '.join(added)} - {fix}")

        _, _, source, module_bazel = expected_entry(module)
        version_dir = REGISTRY_DIR / "modules" / name / version
        actual_source = git_show(f":{version_dir}/source.json")
        if actual_source is None or version not in registry_versions(name):
            errors.append(f"{module}: there's no registry entry for version {version} of {name} - {fix}")
        elif json.loads(actual_source) != source or git_show(f":{version_dir}/MODULE.bazel") != module_bazel:
            errors.append(
                f"{module}: the registry entry for version {version} of {name} ({version_dir}) is out of date with "
                f"{module}/ (e.g. it changed after the entry was written, or the base branch changed it too - merge "
                f"it in first) - {fix}"
            )
    return errors


# --- Releasing ---------------------------------------------------------------


def releasable() -> list[str]:
    lines = []
    for module in module_dirs():
        name, version = parse_module_decl(Path(module, "MODULE.bazel").read_text())
        if (REGISTRY_DIR / "modules" / name / version / "source.json").exists():
            lines.append(f"{module} {release_tag(module, version)}")
    return lines


def verify_archive(module: str, data: bytes) -> None:
    name, version = parse_module_decl(staged_module_bazel(module))
    source_json = REGISTRY_DIR / "modules" / name / version / "source.json"
    expected = json.loads(source_json.read_text())["integrity"]
    actual = sri_sha256(data)
    if actual != expected:
        raise Error(f"{module}'s archive has integrity {actual}, but {source_json} says {expected}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command", required=True)
    bump_parser = subparsers.add_parser("bump", help="set changed modules' versions from the title, and register them")
    bump_parser.add_argument("--title", help="the pull request's (Conventional Commit) title")
    bump_parser.add_argument("--base", help="git ref being merged into (default: origin/main, or else main)")
    check_parser = subparsers.add_parser("check", help="check every changed module has the right, registered version")
    check_parser.add_argument("--title", required=True, help="the pull request's (Conventional Commit) title")
    check_parser.add_argument("--base", required=True, help="git ref being merged into, e.g. origin/main")
    add_parser = subparsers.add_parser("add", help="write and stage the registry entry for a module's current version")
    add_parser.add_argument("module")
    subparsers.add_parser("releasable", help="list modules whose current version has a registry entry")
    archive_parser = subparsers.add_parser("archive", help="build a module's release archive")
    archive_parser.add_argument("module")
    archive_parser.add_argument("--out", required=True, type=Path)
    archive_parser.add_argument(
        "--verify", action="store_true", help="fail unless it matches the registry entry for the current version"
    )
    args = parser.parse_args()
    if args.command == "archive":
        args.out = args.out.resolve()

    # Paths here are all relative to the repository root.
    os.chdir(git("rev-parse", "--show-toplevel").decode().strip())

    errors = []
    try:
        if args.command == "bump":
            bump(args.base, args.title)
        elif args.command == "check":
            errors = check(args.base, args.title)
        elif args.command == "add":
            add(args.module)
        elif args.command == "releasable":
            print("\n".join(releasable()))
        elif args.command == "archive":
            data = build_archive(args.module)
            if args.verify:
                verify_archive(args.module, data)
            args.out.write_bytes(data)
            print(f"Wrote {args.out} ({sri_sha256(data)})")
    except Error as e:
        errors = [str(e)]

    for error in errors:
        if "GITHUB_ACTIONS" in os.environ:
            # A GitHub annotation - newlines have to be URL-encoded in one.
            print("::error::" + error.replace("\n", "%0A"))
        else:
            print(f"ERROR: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
