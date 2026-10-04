# Regenerates ../private/kubectl_versions.bzl: a mirror of kubectl 1.x
# release checksums, used by extensions.bzl as the default `sha256` for a
# `k8s.kubectl(...)` tag that doesn't supply one for a given platform.
#
# Incremental, like every other mirror script in this repo: only versions not
# already present in the existing kubectl_versions.bzl are fetched at all -
# existing entries are carried over as-is, never re-fetched or re-verified.
# Here that's essential, not just an optimization - kubectl
# actually signs its release binaries via sigstore/cosign keyless signing (a
# `.sig`/`.cert` pair alongside each binary), verified here (see
# `verify-and-hash` below), unlike kustomize/OPA's plain-HTTPS-only mirrors.
# But that verification is over the *binary itself*, not a small checksum
# file, and Kubernetes has backported signing to ~180 historical patch
# releases across many still-active minor lines - verifying all of them, for
# every platform, would mean downloading on the order of 900 full kubectl
# binaries (tens of GB) on every single mirror refresh. Only ever verifying
# *new* releases as they ship keeps a normal refresh cheap (typically zero
# downloads - nothing to do until the next kubectl patch is actually cut)
# without ever taking on that one-time cost. Existing entries predate this
# approach and were plain-HTTPS-fetched, not cosign-verified; only entries
# added from here on carry that guarantee.
#
# A version without a signature (kubectl releases older than sigstore
# adoption, or any that just don't have one for whatever reason) falls back
# to the same plain-HTTPS `<binary>.sha256` fetch every other mirror script
# in this repo uses.
#
# Needs a real `cosign` binary on PATH (unlike the `gpg` rules_terraform's/
# this module's Helm mirror shell out to, this repo's only sigstore
# dependency) - see https://docs.sigstore.dev/system_config/installation/.
#
#   cd k8s && bazel run //scripts:mirror_kubectl_versions

const GITHUB_API = "https://api.github.com/repos/kubernetes/kubernetes/releases"
const DL_K8S_IO = "https://dl.k8s.io"
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

# The identity Kubernetes' own release automation signs with - not
# documented anywhere obvious (unlike Helm's public KEYS file); found by
# decoding a real release's kubectl.cert (`base64 -d kubectl.cert | openssl
# x509 -noout -text`) and reading its Subject Alternative Name / OIDC issuer
# extension. If Kubernetes ever rotates the service account or OIDC provider
# its release pipeline signs with, this needs updating to match -
# verification will otherwise start failing (safely - see `verify-and-hash`,
# a failure is skipped, never silently trusted) for every new release.
const KREL_IDENTITY = "krel-staging@k8s-releng-prod.iam.gserviceaccount.com"
const KREL_ISSUER = "https://accounts.google.com"

const PLATFORMS = {
    darwin_amd64: [darwin amd64]
    darwin_arm64: [darwin arm64]
    linux_amd64: [linux amd64]
    linux_arm64: [linux arm64]
    windows_amd64: [windows amd64]
}

def fetch [url: string]: nothing -> binary {
    http get --raw --headers [User-Agent $USER_AGENT] $url | into binary
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

# The versions already mirrored in `versions_file` (its `KUBECTL_VERSIONS =
# {...}`), if it exists - only versions that aren't in it yet are looked up.
# (Nushell's `from json` accepts the trailing commas buildifier, which formats
# the committed file, adds.)
def load-existing [versions_file: string]: nothing -> record {
    if not ($versions_file | path exists) {
        return {}
    }
    let found = (open --raw $versions_file | parse --regex '(?s)KUBECTL_VERSIONS\s*=\s*(?<json>\{.*\})\s*$')
    if ($found | is-empty) {
        error make {msg: $"Could not find KUBECTL_VERSIONS = {...} in existing ($versions_file)"}
    }
    $found.0.json | from json
}

def kubectl-url [version: string, platform: string, suffix: string = ""]: nothing -> string {
    let os_arch = ($PLATFORMS | get $platform)
    let ext = if $os_arch.0 == "windows" { ".exe" } else { "" }
    $"($DL_K8S_IO)/release/v($version)/bin/($os_arch.0)/($os_arch.1)/kubectl($ext)($suffix)"
}

# Plain-HTTPS fallback for a version/platform with no signature to verify.
def fetch-sha256 [version: string, platform: string]: nothing -> any {
    try {
        fetch (kubectl-url $version $platform ".sha256") | decode utf-8 | split words | first
    } catch {
        print --stderr $"> No sha256 for kubectl ($version) ($platform), skipping"
        null
    }
}

# Downloads, cosign-verifies, and hashes `version`/`platform`'s binary.
#
# Returns the verified sha256 hex digest, or {unsigned: true} if there's no
# signature (the caller should fall back to `fetch-sha256`), or null if it's
# unverifiable (skipped entirely, same as every other mirror script's own
# "couldn't confirm it, don't guess" convention - never falls back to
# trusting an unverified hash for something that claimed to be signed but
# didn't check out).
def verify-and-hash [version: string, platform: string]: nothing -> any {
    let sig = (try { fetch (kubectl-url $version $platform ".sig") } catch { null })
    if $sig == null {
        return {unsigned: true}
    }
    let cert = (fetch (kubectl-url $version $platform ".cert"))

    print --stderr $"> Downloading kubectl ($version) ($platform) to verify..."
    let binary = (fetch (kubectl-url $version $platform))

    let dir = (mktemp --directory)
    let bin_path = ($dir | path join kubectl)
    let sig_path = ($dir | path join kubectl.sig)
    let cert_path = ($dir | path join kubectl.cert)
    $binary | save --raw $bin_path
    $sig | save --raw $sig_path
    $cert | save --raw $cert_path
    let result = (
        ^cosign verify-blob
            --signature $sig_path
            --certificate $cert_path
            --certificate-identity $KREL_IDENTITY
            --certificate-oidc-issuer $KREL_ISSUER
            $bin_path
        | complete
    )
    rm --recursive --force $dir

    if $result.exit_code != 0 {
        let reason = ($result.stderr | str trim | lines | last 1 | str join)
        print --stderr $"> Could not verify signature for kubectl ($version) ($platform), skipping: ($reason)"
        return null
    }
    $binary | hash sha256
}

def main [] {
    let workspace = ($env.BUILD_WORKSPACE_DIRECTORY? | default "")
    if $workspace == "" {
        error make {msg: "BUILD_WORKSPACE_DIRECTORY not set, please run via `bazel run ...`"}
    }
    let versions_file = ($workspace | path join private kubectl_versions.bzl)

    let existing = (load-existing $versions_file)
    print --stderr $"($existing | columns | length) versions already mirrored"

    let new_versions = (list-new-versions ($existing | columns))
    print --stderr $"Found ($new_versions | length) new kubectl ($MAJOR).x release\(s\) to process"

    let new_entries = ($new_versions | reduce --fold {} {|version, acc|
        print --stderr $"Processing kubectl ($version)..."
        let platform_shas = ($PLATFORMS | columns | reduce --fold {} {|platform, shas|
            let verified = (verify-and-hash $version $platform)
            let sha256 = if ($verified | describe | str starts-with "record") {
                fetch-sha256 $version $platform
            } else {
                $verified
            }
            if $sha256 == null { $shas } else { $shas | insert $platform $sha256 }
        })
        if ($platform_shas | is-empty) { $acc } else { $acc | insert $version $platform_shas }
    })
    # Newest first, as the release listings are, ahead of what was already there.
    let result = ($new_entries | merge $existing)

    let header = [
        r#'"""GENERATED incrementally (see this script's own header comment) by'#
        '`cd k8s && bazel run //scripts:mirror_kubectl_versions`.'
        ''
        $"A mirror of kubectl ($MAJOR).x release checksums, used by extensions.bzl as the"
        "default `sha256` for a `k8s.kubectl(...)` tag that doesn't supply one for a"
        "given platform - an explicit `sha256` on the tag always overrides this."
        "Entries for a signed release are cosign-verified against Kubernetes' own"
        "release identity (`KREL_IDENTITY`/`KREL_ISSUER` in this script); entries"
        "predating this script's cosign support, or any release with no signature at"
        "all, are plain-HTTPS-fetched instead - not distinguished here, but never"
        "mixed silently: a signed release that fails verification is skipped"
        'entirely, never falls back to unverified.'
        '"""'
        ''
    ] | str join "\n"
    $"($header)\nKUBECTL_VERSIONS = ($result | to json --indent 2)\n" | save --force $versions_file

    print --stderr $"Wrote ($versions_file)"
}
