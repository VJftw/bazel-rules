#!/usr/bin/env python3
"""Regenerates ../private/versions.bzl: a GPG-verified mirror of Terraform 1.x
release checksums, used by extensions.bzl as the default `sha256` for a
`terraform.version(...)` tag that doesn't supply one for a given platform.

rules_terraform's own build actions/runner all run through the hermetic
Python toolchain rather than bash - this is the same interpreter, but it
still shells out to a real `gpg` binary on PATH for signature verification:
there's no pure-Python (stdlib or otherwise, without adding a real
dependency) equivalent hermetic enough to trust for that.

rules_python is only a dev_dependency of rules_terraform's own MODULE.bazel,
so this must be run with build/rules/terraform itself as the workspace root,
not a consumer's:

  cd build/rules/terraform && bazel run //scripts:mirror_terraform_versions
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

HASHICORP_RELEASES_BASE_URL = "https://releases.hashicorp.com"
HASHICORP_PGP_KEY_URL = "https://www.hashicorp.com/.well-known/pgp-key.txt"
FETCH_TIMEOUT_SECONDS = 30

VERSION_HREF_RE = re.compile(r'href="/terraform/([^"]+)/"')
VERSION_RE = re.compile(r"^1\.[0-9]+\.[0-9]+$")
PLATFORM_RE = re.compile(r"^terraform_[0-9.]+_(.+)\.zip$")


def _fetch(url):
    with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT_SECONDS) as resp:
        return resp.read()


def _list_terraform_versions():
    html = _fetch(HASHICORP_RELEASES_BASE_URL + "/terraform").decode("utf-8")
    # Newest-first, matching the page's own listing order - no explicit
    # sort: reordering would need a version-aware (not lexical) sort anyway,
    # and the page already gives us that for free.
    return [v for v in VERSION_HREF_RE.findall(html) if VERSION_RE.match(v)]


def _import_hashicorp_key(gnupg_home):
    # Fetched fresh each run rather than hardcoded, so a key rotation
    # doesn't silently break this - see
    # https://www.hashicorp.com/trust/security.
    key_bytes = _fetch(HASHICORP_PGP_KEY_URL)

    show = subprocess.run(
        ["gpg", "--with-colons", "--show-keys"],
        input=key_bytes,
        capture_output=True,
        check=True,
    )
    key_id = None
    for line in show.stdout.decode().splitlines():
        fields = line.split(":")
        if fields[0] == "pub":
            key_id = fields[4][-8:]
            break
    if not key_id:
        sys.exit("Could not extract a key ID from " + HASHICORP_PGP_KEY_URL)

    env = dict(os.environ, GNUPGHOME=gnupg_home)
    subprocess.run(["gpg", "--quiet", "--import"], input=key_bytes, env=env, check=True)
    return key_id


def _fetch_verified_sums(version, key_id, gnupg_home):
    """Fetches + GPG-verifies `version`'s SHA256SUMS. Returns its raw bytes, or None if unavailable/unverifiable."""
    base = "%s/terraform/%s/terraform_%s" % (HASHICORP_RELEASES_BASE_URL, version, version)
    try:
        sums = _fetch(base + "_SHA256SUMS")
        sig = _fetch(base + "_SHA256SUMS.%s.sig" % key_id)
    except urllib.error.HTTPError:
        print("> No SHA256SUMS for %s, skipping" % version, file=sys.stderr)
        return None

    with tempfile.TemporaryDirectory() as d:
        sums_path = os.path.join(d, "sums")
        sig_path = os.path.join(d, "sums.sig")
        with open(sums_path, "wb") as f:
            f.write(sums)
        with open(sig_path, "wb") as f:
            f.write(sig)
        env = dict(os.environ, GNUPGHOME=gnupg_home)
        result = subprocess.run(["gpg", "--verify", sig_path, sums_path], env=env, capture_output=True)

    if b"Good signature" not in result.stderr:
        print("> Could not verify signature for Terraform %s, skipping" % version, file=sys.stderr)
        return None
    return sums


def _parse_platform_shas(sums):
    platforms = {}
    for line in sums.decode("utf-8").splitlines():
        if not line.strip():
            continue
        sha256sum, filename = line.split(None, 1)
        m = PLATFORM_RE.match(filename)
        if m:
            platforms[m.group(1)] = sha256sum
    return platforms


def main():
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if not workspace:
        sys.exit("BUILD_WORKSPACE_DIRECTORY not set, please run via `bazel run ...`")
    versions_file = os.path.join(workspace, "private", "versions.bzl")

    with tempfile.TemporaryDirectory() as gnupg_home:
        os.chmod(gnupg_home, 0o700)
        key_id = _import_hashicorp_key(gnupg_home)

        terraform_versions = _list_terraform_versions()
        print("Found %d Terraform 1.x releases" % len(terraform_versions), file=sys.stderr)

        result = {}
        for version in terraform_versions:
            print("Processing Terraform %s..." % version, file=sys.stderr)
            sums = _fetch_verified_sums(version, key_id, gnupg_home)
            if sums is not None:
                result[version] = _parse_platform_shas(sums)

    with open(versions_file, "w", encoding="utf-8") as f:
        f.write(
            '"""GENERATED by `cd build/rules/terraform && bazel run '
            '//scripts:mirror_terraform_versions`.\n\n'
            "A mirror of Terraform 1.x release checksums, fetched from\n"
            "releases.hashicorp.com and GPG-verified against HashiCorp's published\n"
            "signature for each release (key %s -\n"
            "https://www.hashicorp.com/trust/security). Used by `extensions.bzl` as the\n"
            "default `sha256` for a `terraform.version(...)` tag that doesn't supply one\n"
            "for a given platform - an explicit `sha256` on the tag always overrides\n"
            'this.\n"""\n\n' % key_id
        )
        f.write("TERRAFORM_VERSIONS = ")
        json.dump(result, f, indent=2)
        f.write("\n")

    print("Wrote %s" % versions_file, file=sys.stderr)


if __name__ == "__main__":
    main()
