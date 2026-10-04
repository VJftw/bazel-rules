# Regenerates ../private/kustomize_versions.bzl: a mirror of kustomize 5.x
# release checksums, used by extensions.bzl as the default `sha256` for a
# `k8s.kustomize(...)` tag that doesn't supply one for a given platform.
#
# Unlike Terraform's own mirror (see rules_terraform's own
# scripts/mirror_terraform_versions.nu), kustomize doesn't publish a
# signature alongside its release `checksums.txt` - so this is plain
# HTTPS-fetched, not GPG-verified. Bounded to the 5.x line (like Terraform's
# own 1.x bound) - extend `MAJOR` below once kustomize ships a 6.x.
#
#   cd k8s && bazel run //scripts:mirror_kustomize_versions

const GITHUB_API = "https://api.github.com/repos/kubernetes-sigs/kustomize/releases"
const USER_AGENT = "bazel-rules-mirror-script"

# Authenticates to the GitHub API with $GITHUB_TOKEN when it's set (e.g. in
# the nightly workflow) - unauthenticated requests are limited to 60 an hour.
def github-api-headers []: nothing -> list<string> {
    let token = ($env.GITHUB_TOKEN? | default "")
    if $token == "" {
        [User-Agent $USER_AGENT]
    } else {
        [User-Agent $USER_AGENT Authorization $"Bearer ($token)"]
    }
}
const MAJOR = "5"

# Releases are only looked up until this many in a row are already mirrored -
# see `list-new-versions`.
const STOP_AFTER_MIRRORED = 20

# The versions in a page of GitHub releases that this mirror covers.
def release-versions [releases: list]: nothing -> list<string> {
    $releases
    | get tag_name
    | parse --regex ('^kustomize/v(?<version>' + $MAJOR + '\.[0-9]+\.[0-9]+)$')
    | get version
}

# The versions released since `mirrored` were. GitHub lists releases newest
# (created) first, so this walks that list until it's seen STOP_AFTER_MIRRORED
# releases in a row that are already mirrored - which still catches a release
# for an older line cut after newer ones (e.g. a backported patch), or one
# whose assets were only uploaded after the last refresh, but never pages back
# through old releases that never had anything to mirror.
def list-new-versions [mirrored: list<string>]: nothing -> list<string> {
    generate {|state|
        if $state.done { return {} }
        let releases = (http get --headers (github-api-headers) $"($GITHUB_API)?per_page=100&page=($state.page)")
        if ($releases | is-empty) { return {} }
        mut run = $state.run
        mut new = []
        for version in (release-versions $releases) {
            if $version in $mirrored {
                $run += 1
                if $run >= $STOP_AFTER_MIRRORED { break }
            } else {
                $run = 0
                $new = ($new | append $version)
            }
        }
        {out: $new, next: {page: ($state.page + 1), run: $run, done: ($run >= $STOP_AFTER_MIRRORED)}}
    } {page: 1, run: 0, done: false}
    | flatten
}

def fetch-checksums [version: string]: nothing -> any {
    let url = $"https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v($version)/checksums.txt"
    try {
        http get --raw --headers [User-Agent $USER_AGENT] $url | decode utf-8
    } catch {
        print --stderr $"> No checksums.txt for ($version), skipping"
        null
    }
}

# {platform: sha256}, e.g. {linux_amd64: ...}, from a checksums.txt.
def parse-platform-shas []: string -> record {
    lines
    | where {|line| ($line | str trim) != "" }
    | parse --regex '^(?<sha256>\S+)\s+kustomize_v[0-9.]+_(?<platform>.+)\.(?:tar\.gz|zip)\s*$'
    | reduce --fold {} {|row, acc| $acc | upsert $row.platform $row.sha256 }
}

# The versions already mirrored in `versions_file` (its `KUSTOMIZE_VERSIONS = {...}`), if
# it exists - only versions that aren't in it yet are looked up. (Nushell's
# `from json` accepts the trailing commas buildifier, which formats the
# committed file, adds.)
def load-existing [versions_file: string]: nothing -> record {
    if not ($versions_file | path exists) {
        return {}
    }
    let found = (open --raw $versions_file | parse --regex '(?s)KUSTOMIZE_VERSIONS\s*=\s*(?<json>\{.*\})\s*$')
    if ($found | is-empty) {
        error make {msg: $"Could not find KUSTOMIZE_VERSIONS = {...} in existing ($versions_file)"}
    }
    $found.0.json | from json
}

def main [] {
    let workspace = ($env.BUILD_WORKSPACE_DIRECTORY? | default "")
    if $workspace == "" {
        error make {msg: "BUILD_WORKSPACE_DIRECTORY not set, please run via `bazel run ...`"}
    }
    let versions_file = ($workspace | path join private kustomize_versions.bzl)

    let existing = (load-existing $versions_file)
    print --stderr $"($existing | columns | length) versions already mirrored"

    let versions = (list-new-versions ($existing | columns))
    print --stderr $"Found ($versions | length) kustomize ($MAJOR).x release\(s\) not mirrored yet"

    let new_entries = ($versions | reduce --fold {} {|version, acc|
        print --stderr $"Processing kustomize ($version)..."
        let checksums = (fetch-checksums $version)
        if $checksums == null { $acc } else { $acc | insert $version ($checksums | parse-platform-shas) }
    })
    # Newest first, as the release listings are, ahead of what was already there.
    let result = ($new_entries | merge $existing)

    let header = [
        '"""GENERATED by `cd k8s && bazel run //scripts:mirror_kustomize_versions`.'
        ''
        $"A mirror of kustomize ($MAJOR).x release checksums, fetched from"
        "kustomize's own GitHub release `checksums.txt` (plain HTTPS, not"
        "GPG-verified - kustomize doesn't publish a signature for it, unlike"
        "Terraform's own SHA256SUMS/.sig). Used by extensions.bzl as the default"
        "`sha256` for a `k8s.kustomize(...)` tag that doesn't supply one for a"
        'given platform - an explicit `sha256` on the tag always overrides this.'
        '"""'
        ''
    ] | str join "\n"
    $"($header)\nKUSTOMIZE_VERSIONS = ($result | to json --indent 2)\n" | save --force $versions_file

    print --stderr $"Wrote ($versions_file)"
}
