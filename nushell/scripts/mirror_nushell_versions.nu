# Regenerates ../private/versions.bzl: a mirror of Nushell release
# checksums, used by extensions.bzl as the default `sha256` for a
# `nushell.version(...)` tag that doesn't supply one for a given platform.
#
# Plain HTTPS-fetched from Nushell's own combined `SHA256SUMS` release asset
# (one file per version, covering every platform - like Hugo's/kustomize's
# own mirrors, not GPG-verified like Terraform's/Helm's: Nushell doesn't
# publish a signature for it). Older releases that don't publish a
# `SHA256SUMS` at all are skipped.
#
# Like Hugo, Nushell has never shipped past 0.x, so there's no major version
# line to bound this to - this mirrors every non-prerelease version the
# GitHub API returns that has a `SHA256SUMS`.
#
# Incremental: versions already in the existing file are carried over as-is,
# never re-fetched or re-verified - only releases published since the last
# refresh are looked up (see `list-new-versions`), so a refresh (e.g. the
# nightly workflow's) is cheap when nothing new has shipped.
#
#   cd nushell && bazel run //scripts:mirror_nushell_versions

const GITHUB_API = "https://api.github.com/repos/nushell/nushell/releases"
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

# Matches extensions.bzl's own _TRIPLES and asset naming - kept in sync by
# hand.
const TRIPLES = {
    linux_amd64: "x86_64-unknown-linux-musl"
    linux_arm64: "aarch64-unknown-linux-musl"
    darwin_amd64: "x86_64-apple-darwin"
    darwin_arm64: "aarch64-apple-darwin"
    windows_amd64: "x86_64-pc-windows-msvc"
    windows_arm64: "aarch64-pc-windows-msvc"
}

def asset-name [version: string, platform: string]: nothing -> string {
    let ext = if ($platform | str starts-with "windows_") { "zip" } else { "tar.gz" }
    $"nu-($version)-($TRIPLES | get $platform).($ext)"
}

# Releases are only looked up until this many in a row are already mirrored -
# see `list-new-versions`.
const STOP_AFTER_MIRRORED = 20

# The versions in a page of GitHub releases that this mirror covers.
def release-versions [releases: list]: nothing -> list<string> {
    $releases
    | where {|r| not $r.prerelease and not $r.draft and ($r.tag_name =~ '^[0-9]+\.[0-9]+\.[0-9]+$') }
    | get tag_name
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

# {asset name: sha256} from a version's SHA256SUMS, or null if it has none.
def fetch-sha256sums [version: string]: nothing -> any {
    let url = $"https://github.com/nushell/nushell/releases/download/($version)/SHA256SUMS"
    let content = (try { http get --raw --headers [User-Agent $USER_AGENT] $url | decode utf-8 } catch { null })
    if $content == null {
        print --stderr $"> No SHA256SUMS for nushell ($version), skipping"
        return null
    }
    $content
    | lines
    | parse --regex '^(?<digest>[0-9a-f]{64})\s+\*?(?<name>\S+)$'
    | reduce --fold {} {|row, acc| $acc | insert $row.name $row.digest }
}

# The versions already mirrored in `versions_file` (its `NUSHELL_VERSIONS = {...}`), if
# it exists - only versions that aren't in it yet are looked up. (Nushell's
# `from json` accepts the trailing commas buildifier, which formats the
# committed file, adds.)
def load-existing [versions_file: string]: nothing -> record {
    if not ($versions_file | path exists) {
        return {}
    }
    let found = (open --raw $versions_file | parse --regex '(?s)NUSHELL_VERSIONS\s*=\s*(?<json>\{.*\})\s*$')
    if ($found | is-empty) {
        error make {msg: $"Could not find NUSHELL_VERSIONS = {...} in existing ($versions_file)"}
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
    print --stderr $"Found ($versions | length) Nushell release\(s\) not mirrored yet"

    let new_entries = ($versions | reduce --fold {} {|version, acc|
        print --stderr $"Processing Nushell ($version)..."
        let sums = (fetch-sha256sums $version)
        if $sums == null { return $acc }
        let platform_shas = ($TRIPLES | columns | reduce --fold {} {|platform, shas|
            let digest = ($sums | get --optional (asset-name $version $platform))
            if $digest == null { $shas } else { $shas | insert $platform $digest }
        })
        if ($platform_shas | is-empty) { $acc } else { $acc | insert $version $platform_shas }
    })
    # Newest first, as the release listings are, ahead of what was already there.
    let result = ($new_entries | merge $existing)

    let header = [
        '"""GENERATED by `cd nushell && bazel run //scripts:mirror_nushell_versions`.'
        ''
        "A mirror of Nushell release checksums, fetched plain-HTTPS from Nushell's"
        "own GitHub release `SHA256SUMS` files (not signature-verified - see this"
        "script's own header comment for why). Used by extensions.bzl as the"
        "default `sha256` for a `nushell.version(...)` tag that doesn't supply one"
        'for a given platform - an explicit `sha256` on the tag always overrides this.'
        '"""'
        ''
    ] | str join "\n"
    $"($header)\nNUSHELL_VERSIONS = ($result | to json --indent 2)\n" | save --force $versions_file

    print --stderr $"Wrote ($versions_file)"
}
