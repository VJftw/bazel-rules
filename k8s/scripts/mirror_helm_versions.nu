# Regenerates ../private/helm_versions.bzl: a GPG-verified mirror of Helm
# 3.x release checksums, used by extensions.bzl as the default `sha256` for a
# `k8s.helm(...)` tag that doesn't supply one for a given platform.
#
# Like rules_terraform's own mirror script, this shells out to a real `gpg`
# binary on PATH for signature verification.
#
# Helm doesn't publish a plain checksums manifest as a GitHub release asset
# (only detached `.asc` signatures) - the plain per-platform
# `<archive>.sha256` actually lives at get.helm.sh itself (see helm's own
# scripts/get-helm-3 installer), verified here against the matching
# `<archive>.sha256.asc` detached signature from the GitHub release, using
# Helm's own published `KEYS` file. Bounded to the 3.x line (like
# Terraform's own 1.x bound) - extend `MAJOR` below once/if a new stable
# major ships.
#
#   cd k8s && bazel run //scripts:mirror_helm_versions

const GITHUB_API = "https://api.github.com/repos/helm/helm/releases"
const GET_HELM_BASE_URL = "https://get.helm.sh"
const HELM_KEYS_URL = "https://raw.githubusercontent.com/helm/helm/main/KEYS"
const USER_AGENT = "bazel-rules-mirror-script"
const MAJOR = "3"

# Every platform helm publishes a release for - not just the ones this
# module's own _PLATFORMS registers toolchains for, so the mirror stays
# useful even if that set grows later.
const PLATFORMS = [
    darwin-amd64
    darwin-arm64
    linux-386
    linux-amd64
    linux-arm
    linux-arm64
    linux-loong64
    linux-ppc64le
    linux-riscv64
    linux-s390x
    windows-amd64
    windows-arm64
]

def fetch [url: string]: nothing -> binary {
    http get --raw --headers [User-Agent $USER_AGENT] $url | into binary
}

def list-versions []: nothing -> list<string> {
    generate {|page|
        let releases = (http get --headers [User-Agent $USER_AGENT] $"($GITHUB_API)?per_page=100&page=($page)")
        if ($releases | is-empty) { {} } else { {out: $releases, next: ($page + 1)} }
    } 1
    | flatten
    | get tag_name
    | parse --regex ('^v(?<version>' + $MAJOR + '\.[0-9]+\.[0-9]+)$')
    | get version
}

def archive-ext [platform: string]: nothing -> string {
    if ($platform | str starts-with "windows-") { "zip" } else { "tar.gz" }
}

def import-helm-keys [gnupg_home: string] {
    # Fetched fresh each run rather than hardcoded, so a key rotation/new
    # maintainer doesn't silently break this.
    let keys = (fetch $HELM_KEYS_URL)
    with-env {GNUPGHOME: $gnupg_home} {
        $keys | ^gpg --quiet --import
    }
}

# Fetches + GPG-verifies `version`/`platform`'s sha256. Returns the hex
# digest, or null if unavailable/unverifiable.
def fetch-verified-sha256 [version: string, platform: string, gnupg_home: string]: nothing -> any {
    let archive = $"helm-v($version)-($platform).(archive-ext $platform)"
    let fetched = (try {
        {
            sha256_raw: (fetch $"($GET_HELM_BASE_URL)/($archive).sha256")
            sig: (fetch $"https://github.com/helm/helm/releases/download/v($version)/($archive).sha256.asc")
        }
    } catch {
        null
    })
    if $fetched == null {
        print --stderr $"> No sha256/signature for helm ($version) ($platform), skipping"
        return null
    }

    let dir = (mktemp --directory)
    let sum_path = ($dir | path join sum)
    let sig_path = ($dir | path join sum.asc)
    # The signature is over the exact bytes of the fetched .sha256 file
    # (verified empirically) - write it back out unmodified, not just the
    # hex digest extracted below for the return value: gpg verification is
    # byte-exact, so a reconstructed file missing the original's trailing
    # newline/whitespace would fail to verify even though the hash value
    # itself is identical.
    $fetched.sha256_raw | save --raw $sum_path
    $fetched.sig | save --raw $sig_path
    let result = (with-env {GNUPGHOME: $gnupg_home} {
        ^gpg --verify $sig_path $sum_path | complete
    })
    rm --recursive --force $dir

    if not ($result.stderr | str contains "Good signature") {
        print --stderr $"> Could not verify signature for helm ($version) ($platform), skipping"
        return null
    }
    $fetched.sha256_raw | decode utf-8 | split words | first
}

def main [] {
    let workspace = ($env.BUILD_WORKSPACE_DIRECTORY? | default "")
    if $workspace == "" {
        error make {msg: "BUILD_WORKSPACE_DIRECTORY not set, please run via `bazel run ...`"}
    }
    let versions_file = ($workspace | path join private helm_versions.bzl)

    let gnupg_home = (mktemp --directory)
    import-helm-keys $gnupg_home

    let versions = (list-versions)
    print --stderr $"Found ($versions | length) Helm ($MAJOR).x releases"

    let result = ($versions | reduce --fold {} {|version, acc|
        print --stderr $"Processing Helm ($version)..."
        let platform_shas = ($PLATFORMS | reduce --fold {} {|platform, shas|
            let sha256 = (fetch-verified-sha256 $version $platform $gnupg_home)
            if $sha256 == null { $shas } else { $shas | insert ($platform | str replace "-" "_") $sha256 }
        })
        if ($platform_shas | is-empty) { $acc } else { $acc | insert $version $platform_shas }
    })
    rm --recursive --force $gnupg_home

    let header = [
        '"""GENERATED by `cd k8s && bazel run //scripts:mirror_helm_versions`.'
        ''
        $"A GPG-verified mirror of Helm ($MAJOR).x release checksums, fetched from"
        "get.helm.sh (the plain `<archive>.sha256`) and verified against the"
        "matching GitHub release `<archive>.sha256.asc` detached signature, using"
        "Helm's own published KEYS file"
        "(https://github.com/helm/helm/blob/main/KEYS). Used by extensions.bzl as"
        "the default `sha256` for a `k8s.helm(...)` tag that doesn't supply one for"
        'a given platform - an explicit `sha256` on the tag always overrides this.'
        '"""'
        ''
    ] | str join "\n"
    $"($header)\nHELM_VERSIONS = ($result | to json --indent 2)\n" | save --force $versions_file

    print --stderr $"Wrote ($versions_file)"
}
