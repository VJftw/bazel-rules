# Regenerates ../private/versions.bzl: a mirror of OPA 1.x release
# checksums, used by extensions.bzl as the default `sha256` for an
# `opa.version(...)` tag that doesn't supply one for a given platform.
#
# Plain HTTPS-fetched, not signature-verified: OPA doesn't publish a GPG
# signature (or a sigstore/cosign one, as far as this script's author could
# tell) alongside its per-binary `.sha256` files. Bounded to the 1.x line
# (OPA's pre-1.0 releases used a meaningfully different versioning scheme) -
# like Terraform's own 1.x bound.
#
# Incremental: versions already in the existing file are carried over as-is,
# never re-fetched or re-verified - only releases published since the last
# refresh are looked up (see `list-new-versions`), so a refresh (e.g. the
# nightly workflow's) is cheap when nothing new has shipped.
#
#   cd opa && bazel run //scripts:mirror_opa_versions

const GITHUB_API = "https://api.github.com/repos/open-policy-agent/opa/releases"
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
const MAJOR = "1"

# Matches the asset-naming convention in extensions.bzl's own _ASSET_NAMES -
# kept in sync by hand.
const ASSET_NAMES = {
    linux_amd64: "opa_linux_amd64_static"
    linux_arm64: "opa_linux_arm64_static"
    darwin_amd64: "opa_darwin_amd64"
    darwin_arm64: "opa_darwin_arm64"
    windows_amd64: "opa_windows_amd64.exe"
}

# Releases are only looked up until this many in a row are already mirrored -
# see `list-new-versions`.
const STOP_AFTER_MIRRORED = 20

# The versions in a page of GitHub releases that this mirror covers.
def release-versions [releases: list]: nothing -> list<string> {
    $releases
    | where {|r| not $r.prerelease }
    | get tag_name
    | parse --regex ('^v(?<version>' + $MAJOR + '\.[0-9]+\.[0-9]+)$')
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

def fetch-sha256 [version: string, platform: string]: nothing -> any {
    let asset = ($ASSET_NAMES | get $platform)
    let url = $"https://github.com/open-policy-agent/opa/releases/download/v($version)/($asset).sha256"
    try {
        http get --raw --headers [User-Agent $USER_AGENT] $url | decode utf-8 | split words | first
    } catch {
        print --stderr $"> No sha256 for opa ($version) ($platform), skipping"
        null
    }
}

# The versions already mirrored in `versions_file` (its `OPA_VERSIONS = {...}`), if
# it exists - only versions that aren't in it yet are looked up. (Nushell's
# `from json` accepts the trailing commas buildifier, which formats the
# committed file, adds.)
def load-existing [versions_file: string]: nothing -> record {
    if not ($versions_file | path exists) {
        return {}
    }
    let found = (open --raw $versions_file | parse --regex '(?s)OPA_VERSIONS\s*=\s*(?<json>\{.*\})\s*$')
    if ($found | is-empty) {
        error make {msg: $"Could not find OPA_VERSIONS = {...} in existing ($versions_file)"}
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
    print --stderr $"Found ($versions | length) OPA ($MAJOR).x release\(s\) not mirrored yet"

    let new_entries = ($versions | reduce --fold {} {|version, acc|
        print --stderr $"Processing OPA ($version)..."
        let platform_shas = ($ASSET_NAMES | columns | reduce --fold {} {|platform, shas|
            let sha256 = (fetch-sha256 $version $platform)
            if $sha256 == null { $shas } else { $shas | insert $platform $sha256 }
        })
        if ($platform_shas | is-empty) { $acc } else { $acc | insert $version $platform_shas }
    })
    # Newest first, as the release listings are, ahead of what was already there.
    let result = ($new_entries | merge $existing)

    let header = [
        '"""GENERATED by `cd opa && bazel run //scripts:mirror_opa_versions`.'
        ''
        $"A mirror of OPA ($MAJOR).x release checksums, fetched plain-HTTPS from OPA's"
        "own GitHub release `.sha256` files (not signature-verified - see this"
        "script's own header comment for why). Used by extensions.bzl as the"
        "default `sha256` for an `opa.version(...)` tag that doesn't supply one for"
        'a given platform - an explicit `sha256` on the tag always overrides this.'
        '"""'
        ''
    ] | str join "\n"
    $"($header)\nOPA_VERSIONS = ($result | to json --indent 2)\n" | save --force $versions_file

    print --stderr $"Wrote ($versions_file)"
}
