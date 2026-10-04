# Regenerates ../private/versions.bzl: a mirror of the "extended" Hugo
# release variant's checksums, used by extensions.bzl as the default
# `sha256` for a `hugo.version(...)` tag that doesn't supply one for a given
# platform.
#
# Plain HTTPS-fetched from Hugo's own combined `checksums.txt` release asset
# (one file per version, covering every variant/platform - like kustomize's
# own mirror, not GPG-verified like Terraform's/Helm's: Hugo doesn't publish
# a signature for it). Only the "extended" variant's entries are kept - the
# default (and this module's own recommended) variant; any other variant
# always needs an explicit `sha256`, since mirroring all four would just be
# 4x the size for checksums almost nobody pins the non-default variant
# against.
#
# Unlike every other mirror script in this repo, there's no clean major
# version line to bound this to - Hugo has never shipped past 0.x, so this
# just mirrors every non-prerelease version the GitHub API returns (still
# cheap: one small `checksums.txt` fetch per version, the same reasoning
# kustomize's own mirror relies on for not needing to download full
# binaries).
#
# Incremental: versions already in the existing file are carried over as-is,
# never re-fetched or re-verified - only releases published since the last
# refresh are looked up (see `list-new-versions`), so a refresh (e.g. the
# nightly workflow's) is cheap when nothing new has shipped.
#
#   cd hugo && bazel run //scripts:mirror_hugo_versions

const GITHUB_API = "https://api.github.com/repos/gohugoio/hugo/releases"
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

# Matches extensions.bzl's own _OS_ARCH - kept in sync by hand.
const OS_ARCH_TO_PLATFORM = {
    linux-amd64: "linux_amd64"
    linux-arm64: "linux_arm64"
    darwin-universal: "darwin_universal"
    windows-amd64: "windows_amd64"
    windows-arm64: "windows_arm64"
}

# Releases are only looked up until this many in a row are already mirrored -
# see `list-new-versions`.
const STOP_AFTER_MIRRORED = 20

# The versions in a page of GitHub releases that this mirror covers.
def release-versions [releases: list]: nothing -> list<string> {
    $releases
    | where {|r| not $r.prerelease }
    | get tag_name
    | parse --regex '^v(?<version>[0-9]+\.[0-9]+\.[0-9]+)$'
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
    let url = $"https://github.com/gohugoio/hugo/releases/download/v($version)/hugo_($version)_checksums.txt"
    try {
        http get --raw --headers [User-Agent $USER_AGENT] $url | decode utf-8
    } catch {
        print --stderr $"> No checksums.txt for ($version), skipping"
        null
    }
}

def parse-platform-shas []: string -> record {
    lines
    | where {|line| ($line | str trim) != "" }
    | parse --regex '^(?<sha256>\S+)\s+hugo_extended_[0-9.]+_(?<os_arch>.+)\.(?:tar\.gz|zip|pkg)\s*$'
    | where {|row| $row.os_arch in $OS_ARCH_TO_PLATFORM }
    | reduce --fold {} {|row, acc| $acc | upsert ($OS_ARCH_TO_PLATFORM | get $row.os_arch) $row.sha256 }
}

# The versions already mirrored in `versions_file` (its `HUGO_VERSIONS = {...}`), if
# it exists - only versions that aren't in it yet are looked up. (Nushell's
# `from json` accepts the trailing commas buildifier, which formats the
# committed file, adds.)
def load-existing [versions_file: string]: nothing -> record {
    if not ($versions_file | path exists) {
        return {}
    }
    let found = (open --raw $versions_file | parse --regex '(?s)HUGO_VERSIONS\s*=\s*(?<json>\{.*\})\s*$')
    if ($found | is-empty) {
        error make {msg: $"Could not find HUGO_VERSIONS = {...} in existing ($versions_file)"}
    }
    $found.0.json | from json
}

def main [] {
    let workspace = ($env.BUILD_WORKSPACE_DIRECTORY? | default "")
    if $workspace == "" {
        error make {msg: "BUILD_WORKSPACE_DIRECTORY not set, please run via `bazel run ...`"}
    }
    let versions_file = ($workspace | path join private versions.bzl)

    let existing = (load-existing $versions_file)
    print --stderr $"($existing | columns | length) versions already mirrored"

    let versions = (list-new-versions ($existing | columns))
    print --stderr $"Found ($versions | length) Hugo release\(s\) not mirrored yet"

    let new_entries = ($versions | reduce --fold {} {|version, acc|
        print --stderr $"Processing Hugo ($version)..."
        let checksums = (fetch-checksums $version)
        if $checksums == null { return $acc }
        let platform_shas = ($checksums | parse-platform-shas)
        if ($platform_shas | is-empty) { $acc } else { $acc | insert $version $platform_shas }
    })
    # Newest first, as the release listings are, ahead of what was already there.
    let result = ($new_entries | merge $existing)

    let header = [
        '"""GENERATED by `cd hugo && bazel run //scripts:mirror_hugo_versions`.'
        ''
        r#'A mirror of the "extended" Hugo release variant's checksums, fetched'#
        "from Hugo's own combined `checksums.txt` release asset (plain HTTPS, not"
        "signature-verified - Hugo doesn't publish one). Used by extensions.bzl as"
        "the default `sha256` for a `hugo.version(...)` tag that doesn't supply one"
        'for a given platform, when using the default "extended" variant - an'
        'explicit `sha256` on the tag always overrides this.'
        '"""'
        ''
    ] | str join "\n"
    $"($header)\nHUGO_VERSIONS = ($result | to json --indent 2)\n" | save --force $versions_file

    print --stderr $"Wrote ($versions_file)"
}
