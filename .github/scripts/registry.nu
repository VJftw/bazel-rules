# Manages registry/, this repo's self-hosted Bazel module registry.
#
# Every change to a module's released contents comes with a new version, and
# that version's registry entry, in the same pull request - so registry/ on
# main only ever changes through reviewed pull requests, and nothing ever has
# to push to main directly. The entry's integrity hash is of the module's
# release archive, which is built reproducibly (see `build-archive`), so it
# can be computed before the archive is actually published: `release.yml`
# rebuilds the exact same archive after the pull request merges, checks it
# against the entry, and only then publishes it as a GitHub Release.
#
# The new version follows from the pull request's title, which must be a
# Conventional Commit (https://www.conventionalcommits.org/) - with squash
# merges, it's the commit message that actually lands on main. It applies to
# every module the pull request changes:
#
#   feat(...)!: / fix!: / ...  breaking - a major bump (a minor one while the
#                              module's still 0.x, as 0.x makes no
#                              compatibility promises)
#   feat(...): ...             a minor bump
#   fix(...): ... (or any      a patch bump - the module's released contents
#   other type)                still changed
#
# Run from anywhere in the repository:
#
#   cd .github && bazel run //scripts:registry -- <subcommand> ...
#
# (needs `git` and GNU `tar` on the PATH). See https://bazel.build/external/registry
# for the registry's on-disk format: registry/modules/<name>/metadata.json
# (versions list) and registry/modules/<name>/<version>/{MODULE.bazel,source.json}.

const REGISTRY_DIR = "registry"

# Paths (regexes, relative to a module's own directory) whose changes don't
# need a new version: the examples/ module (its own test suite, not something
# a consumer loads), documentation, and Bazel's own lockfile. They're still
# part of the release archive (BCR's presubmit runs examples/ from it).
const EXEMPT_PATTERNS = ['^examples/' '\.md$' '^MODULE\.bazel\.lock$']

# https://www.conventionalcommits.org/ - the types are @commitlint/config-conventional's.
const CONVENTIONAL_TYPES = [build chore ci docs feat fix perf refactor revert style test]
const CONVENTIONAL_RE = '^(?<type>[a-z]+)(?:\([^()]+\))?(?<breaking>!)?: \S'

# module(...) is the first call in a well-formed MODULE.bazel; take the first
# name=/version= pair, which is enough for this repo's own modules (no need
# for a full Starlark parse here).
const MODULE_DECL_RE = '(?s)^(?<pre>.*?module\s*\()(?<body>.*?)(?<post>\n\).*)$'
const MODULE_NAME_RE = '\bname\s*=\s*"(?<value>[^"]+)"'
const MODULE_VERSION_RE = '\bversion\s*=\s*"(?<value>[^"]+)"'

def fail [msg: string] {
    error make {msg: $msg}
}

def --wrapped git [...args: string]: nothing -> string {
    let result = (^git ...$args | complete)
    if $result.exit_code != 0 {
        fail $"git ($args | str join ' ') failed: ($result.stderr | str trim)"
    }
    $result.stdout
}

# A file's content at `spec` (e.g. `<ref>:<path>`, or `:<path>` for the index), or null if it doesn't exist.
def git-show [spec: string]: nothing -> any {
    let result = (^git show $spec | complete)
    if $result.exit_code == 0 { $result.stdout } else { null }
}

def nul-split []: string -> list<string> {
    $in | split row (char nul) | where $it != ""
}

def sri-sha256 [file: string]: nothing -> string {
    $"sha256-(open --raw $file | hash sha256 --binary | encode base64)"
}

# --- Modules and versions ----------------------------------------------------

def parse-module-decl [text: string]: nothing -> record<name: string, version: string> {
    let decl = ($text | parse --regex $MODULE_DECL_RE)
    if ($decl | is-empty) {
        fail "no module(...) declaration found in MODULE.bazel"
    }
    let body = $decl.0.body
    let name = ($body | parse --regex $MODULE_NAME_RE)
    let version = ($body | parse --regex $MODULE_VERSION_RE)
    if ($name | is-empty) or ($version | is-empty) {
        fail "module(...) is missing name= or version="
    }
    {name: $name.0.value, version: $version.0.value}
}

# `text` with its module(...)'s own version - and nothing else, e.g. a bazel_dep's - set.
def set-module-version [text: string, version: string]: nothing -> string {
    let decl = ($text | parse --regex $MODULE_DECL_RE | first)
    let body = ($decl.body | str replace --regex $MODULE_VERSION_RE $'version = "($version)"')
    $decl.pre + $body + $decl.post
}

def version-key [version: string]: nothing -> list<int> {
    let parts = ($version | split row ".")
    if ($parts | length) != 3 or ($parts | any {|part| $part !~ '^\d+$'}) {
        fail $"version '($version)' isn't a plain MAJOR.MINOR.PATCH version"
    }
    $parts | into int
}

# A string that sorts the same as the version does.
def version-sort-key [version: string]: nothing -> string {
    version-key $version | each {|n| $n | into string | fill --alignment right --character "0" --width 12} | str join "."
}

# "major", "minor" or "patch", from a Conventional Commit `title`.
def bump-level [title: string]: nothing -> string {
    let match = ($title | parse --regex $CONVENTIONAL_RE)
    if ($match | is-empty) or ($match.0.type not-in $CONVENTIONAL_TYPES) {
        fail (
            $"'($title)' isn't a Conventional Commit - it should look like `<type>\(<optional scope>\): <description>`, "
            + $"with `!` before the `:` for a breaking change, where <type> is one of: ($CONVENTIONAL_TYPES | str join ', '). "
            + "See https://www.conventionalcommits.org/"
        )
    }
    if $match.0.breaking == "!" {
        "major"
    } else if $match.0.type == "feat" {
        "minor"
    } else {
        "patch"
    }
}

def bumped [version: any, level: any]: nothing -> string {
    let key = (version-key $version)
    let major = $key.0
    let minor = $key.1
    let patch = $key.2
    if $level == "major" and $major > 0 {
        $"($major + 1).0.0"
    } else if $level in [major minor] { # A breaking change while 0.x is a minor bump.
        $"($major).($minor + 1).0"
    } else {
        $"($major).($minor).($patch + 1)"
    }
}

# Every module in this repo: a top-level directory with a MODULE.bazel staged in git (not dot-directories, e.g. .github's own tooling).
def module-dirs []: nothing -> list<string> {
    git ls-files -z -- "*/MODULE.bazel"
    | nul-split
    | each {|path| $path | split row "/"}
    | where {|parts| ($parts | length) == 2 and not ($parts.0 | str starts-with ".")}
    | each {|parts| $parts.0}
    | uniq
    | sort
}

def is-exempt [relpath: string]: nothing -> bool {
    $EXEMPT_PATTERNS | any {|pattern| $relpath =~ $pattern}
}

# [{module, files}]: each module's staged files, other than EXEMPT_PATTERNS, that differ from `merge_base`.
#
# A MODULE.bazel that only differs in its own version doesn't count - so a
# version `bump` set doesn't make a module count as changed by itself.
def changed-modules [merge_base: string]: nothing -> table<module: string, files: list<string>> {
    let changed = (git diff --cached --name-only -z $merge_base | nul-split)
    module-dirs | each {|module|
        let prefix = $"($module)/"
        let module_bazel = $"($module)/MODULE.bazel"
        mut files = (
            $changed
            | where {|path| $path | str starts-with $prefix}
            | where {|path| not (is-exempt ($path | str substring ($prefix | str length)..))}
        )
        if $module_bazel in $files {
            let base_text = (git-show $"($merge_base):($module_bazel)")
            if $base_text != null {
                let base_version = (parse-module-decl $base_text).version
                if (set-module-version (staged-module-bazel $module) $base_version) == $base_text {
                    $files = ($files | where $it != $module_bazel)
                }
            }
        }
        if ($files | is-not-empty) { {module: $module, files: $files} }
    } | compact
}

def resolve-merge-base [base: string]: nothing -> string {
    try {
        git merge-base $base HEAD | str trim
    } catch {
        fail $"can't find where this branch diverged from '($base)' - is it fetched?"
    }
}

# --- The release archive -----------------------------------------------------

# [{path, mode}]: every staged file in `module`, with its full path and git mode.
def staged-entries [module: string]: nothing -> table<path: string, mode: string> {
    git ls-files --stage -z -- $module | nul-split | each {|line|
        let entry = ($line | parse --regex '(?s)^(?<mode>\d+) (?<blob>[0-9a-f]+) (?<stage>\d)\t(?<path>.*)$' | first)
        if $entry.stage != "0" {
            fail $"($entry.path) has unresolved merge conflicts"
        }
        {path: $entry.path, mode: $entry.mode}
    }
}

# Builds `module`'s release archive from what's staged in git, and returns its
# integrity hash. With `out`, also writes the archive there; with `verify`,
# fails (before writing anything) unless it matches the registry entry for the
# module's current version.
#
# Reproducible - the same staged content always gives byte-for-byte the same
# archive, on any machine - so its hash can be put in the registry before
# it's published:
#
# - Staged content (not the working tree), so untracked/ignored files (e.g.
#   `bazel-*` symlinks) can't leak in, and a pull request's CI and the
#   release after it see exactly the same files.
# - Sorted entries, with fixed ownership, timestamps and permissions (only
#   git's own executable bit carries over: files are checked out under a
#   fixed umask).
# - An uncompressed .tar, since compressors (e.g. zlib vs zlib-ng) can
#   produce different bytes for the same input.
#
# Its root is the module's own contents (no wrapper directory).
def build-archive [module: string, --out: string, --verify]: nothing -> string {
    let entries = (staged-entries $module)
    if ($entries | is-empty) {
        fail $"no files from ($module)/ are staged in git - `git add` them first"
    }

    # Paths relative to the module, with every directory above them too -
    # sorted as the archive's entries (directories with a trailing slash).
    let files = ($entries | get path | each {|path| $path | str substring (($module | str length) + 1)..})
    let dirs = (
        $files
        | each {|path|
            let parts = ($path | split row "/" | drop 1)
            $parts | enumerate | each {|part| $parts | first ($part.index + 1) | str join "/"}
        }
        | flatten
        | uniq
        | each {|dir| $"($dir)/"}
    )
    let names = ($dirs | append $files | sort)

    let tmp = (mktemp --directory)
    try {
        # Git applies its own umask-dependent modes when checking out, so pin it.
        $entries | get path | each {|path| $"($path)(char nul)"} | str join
        | ^sh -c 'umask 022; exec "$@"' sh git checkout-index -z --stdin $"--prefix=($tmp)/"

        let list = ($tmp | path join "names")
        $names | each {|name| $"($name)(char nul)"} | str join | save --raw $list
        let archive = ($tmp | path join "archive.tar")
        ^tar --create --format=ustar --no-recursion --numeric-owner --owner=0 --group=0 --mtime=@0 --directory ($tmp | path join $module) --null --files-from $list --file $archive

        let integrity = (sri-sha256 $archive)
        if $verify {
            let decl = (parse-module-decl (staged-module-bazel $module))
            let source_json = ([$REGISTRY_DIR modules $decl.name $decl.version source.json] | path join)
            let expected = (open $source_json | get integrity)
            if $integrity != $expected {
                fail $"($module)'s archive has integrity ($integrity), but ($source_json) says ($expected)"
            }
        }
        if $out != null {
            cp $archive $out
        }
        $integrity
    } finally {
        rm --recursive --force $tmp
    }
}

def release-tag [module: string, version: string]: nothing -> string {
    $"($module)-v($version)"
}

def archive-name [module: string, version: string]: nothing -> string {
    $"rules_($module)-(release-tag $module $version).tar"
}

def bcr-template [module: string]: nothing -> record {
    open ([.bcr $module metadata.template.json] | path join)
}

# `owner/repo`, from .bcr/<module>/metadata.template.json's `repository`.
def github-repository [module: string]: nothing -> string {
    let repositories = (bcr-template $module | get -o repository | default [] | where {|r| $r | str starts-with "github:"})
    if ($repositories | is-empty) {
        fail $".bcr/($module)/metadata.template.json has no github: repository"
    }
    $repositories.0 | str replace "github:" ""
}

def release-url [module: string, version: string]: nothing -> string {
    $"https://github.com/(github-repository $module)/releases/download/(release-tag $module $version)/(archive-name $module $version)"
}

# --- Registry entries --------------------------------------------------------

def staged-module-bazel [module: string]: nothing -> string {
    let text = (git-show $":($module)/MODULE.bazel")
    if $text == null {
        fail $"($module)/MODULE.bazel isn't staged in git - `git add` it first"
    }
    $text
}

# The name, version, source.json and MODULE.bazel the registry should have for `module`'s staged state.
def expected-entry [module: string]: nothing -> record {
    let module_bazel = (staged-module-bazel $module)
    let decl = (parse-module-decl $module_bazel)
    let source = {
        url: (release-url $module $decl.version)
        integrity: (build-archive $module)
        strip_prefix: ""
    }
    {name: $decl.name, version: $decl.version, source: $source, module_bazel: $module_bazel}
}

def metadata-path [name: string]: nothing -> string {
    [$REGISTRY_DIR modules $name metadata.json] | path join
}

# `name`'s versions in registry/ at `ref` ("" for the index).
def registry-versions [name: string, ref: string = ""]: nothing -> list<string> {
    let text = (git-show $"($ref):(metadata-path $name)")
    if $text == null or $text == "" { [] } else { $text | from json | get versions }
}

def load-metadata [module: string, name: string]: nothing -> record {
    let path = (metadata-path $name)
    if ($path | path exists) {
        return (open $path)
    }
    let template = (bcr-template $module)
    {
        homepage: ($template | get -o homepage | default "")
        maintainers: ($template | get -o maintainers | default [])
        repository: ($template | get -o repository | default [])
        versions: []
        yanked_versions: {}
    }
}

def write-json [path: string, value: any]: nothing -> nothing {
    $"($value | to json --indent 2)\n" | save --force --raw $path
}

def write-metadata [name: string, metadata: record]: nothing -> nothing {
    write-json (metadata-path $name) ($metadata | update versions {|m| $m.versions | sort-by {|v| version-sort-key $v}})
}

# Writes and stages the registry entry for `module`'s staged state.
def add-entry [module: string]: nothing -> nothing {
    let entry = (expected-entry $module)
    let version_dir = ([$REGISTRY_DIR modules $entry.name $entry.version] | path join)
    mkdir $version_dir
    $entry.module_bazel | save --force --raw ($version_dir | path join MODULE.bazel)
    write-json ($version_dir | path join source.json) $entry.source

    mut metadata = (load-metadata $module $entry.name)
    if $entry.version not-in $metadata.versions {
        $metadata = ($metadata | update versions {|m| $m.versions | append $entry.version})
    }
    write-metadata $entry.name $metadata

    git add -- $version_dir (metadata-path $entry.name) | ignore
    print $"($module): wrote and staged ($version_dir)/ \(($entry.source.integrity)\)"
}

# Removes (and stages removing) `name`'s registry entries that this branch added, other than `keep`.
def remove-unreleased [module: string, name: string, merge_base: string, keep: any]: nothing -> nothing {
    let released = (registry-versions $name $merge_base)
    let stale = (registry-versions $name | where {|v| $v not-in $released and $v != $keep})
    if ($stale | is-empty) {
        return
    }
    let metadata = (load-metadata $module $name | update versions {|m| $m.versions | where {|v| $v not-in $stale}})
    for version in $stale {
        let version_dir = ([$REGISTRY_DIR modules $name $version] | path join)
        rm --recursive --force $version_dir
        git rm -r --cached --quiet --ignore-unmatch -- $version_dir | ignore
        print $"($module): removed ($version_dir)/, which this branch added before"
    }
    if ($metadata.versions | is-not-empty) {
        write-metadata $name $metadata
        git add -- (metadata-path $name) | ignore
    } else {
        let name_dir = (metadata-path $name | path dirname)
        rm --recursive --force $name_dir
        git rm -r --cached --quiet --ignore-unmatch -- $name_dir | ignore
    }
}

# The open pull request's title (via `gh`), or else the branch's only commit's subject.
def default-title [merge_base: string]: nothing -> string {
    if (which gh | is-not-empty) {
        let result = (^gh pr view --json title --jq .title | complete)
        if $result.exit_code == 0 and ($result.stdout | str trim | is-not-empty) {
            return ($result.stdout | str trim)
        }
    }
    let subjects = (git log --format=%s $"($merge_base)..HEAD" | lines)
    if ($subjects | length) == 1 {
        return $subjects.0
    }
    fail (
        "can't tell what the pull request's title will be (there's no open pull request for this branch, and it "
        + $"has ($subjects | length) commits) - pass it with --title, e.g. --title 'feat\(opa\): add opa_fmt_test'"
    )
}

# Sets (and stages) `module`'s own version in its MODULE.bazel.
def set-version [module: string, version: string]: nothing -> nothing {
    let path = ([$module MODULE.bazel] | path join)
    open --raw $path | set-module-version $in $version | save --force --raw $path
    git add -- $path | ignore
}

def bump [base: any, title: any]: nothing -> nothing {
    let base = if $base == null {
        if (^git rev-parse --verify --quiet origin/main | complete).exit_code == 0 { "origin/main" } else { "main" }
    } else {
        $base
    }
    let merge_base = (resolve-merge-base $base)
    let title = if $title == null { default-title $merge_base } else { $title }
    let level = (bump-level $title)
    let changed = (changed-modules $merge_base)
    print $"'($title)': a ($level) bump for every changed module"

    for module in (module-dirs) {
        let module_bazel = (staged-module-bazel $module)
        let decl = (parse-module-decl $module_bazel)
        let base_module_bazel = (git-show $"($merge_base):($module)/MODULE.bazel")
        let module_changed = ($changed | where module == $module)

        if ($module_changed | is-empty) {
            remove-unreleased $module $decl.name $merge_base null
            if $base_module_bazel != null {
                let base_version = (parse-module-decl $base_module_bazel).version
                if $decl.version != $base_version {
                    set-version $module $base_version
                    print $"($module): unchanged, so restored its version to ($base_version)"
                }
            }
            continue
        }

        let unstaged = (git diff --name-only -- $module | lines)
        if ($unstaged | is-not-empty) {
            print $"($module): warning: ignoring unstaged changes \(`git add` them and re-run): ($unstaged | str join ', ')"
        }

        mut version = $decl.version
        if $base_module_bazel == null {
            print $"($module): a new module, keeping its version ($version)"
        } else {
            let base_version = (parse-module-decl $base_module_bazel).version
            $version = (bumped $base_version $level)
            set-version $module $version
            print $"($module): version ($base_version) -> ($version)"
        }

        remove-unreleased $module $decl.name $merge_base $version
        add-entry $module
    }
}

def check [base: string, title: string]: nothing -> list<string> {
    let merge_base = (resolve-merge-base $base)
    let changed = (changed-modules $merge_base)
    let fix = "run `bazel run //scripts:registry -- bump` in .github (after staging your changes) and commit the result"

    mut errors = []
    mut level: any = null
    if ($changed | is-not-empty) {
        let result = (try { {level: (bump-level $title)} } catch {|e| {error: $e.msg}})
        if ($result | get -o error) != null {
            $errors = ($errors | append $"the pull request's title: ($result.error)")
        } else {
            $level = $result.level
        }
    }

    for module in (module-dirs) {
        let decl = (parse-module-decl (staged-module-bazel $module))
        let name = $decl.name
        let version = $decl.version
        let released = (registry-versions $name $merge_base)
        let added = (registry-versions $name | where {|v| $v not-in $released})
        let base_module_bazel = (git-show $"($merge_base):($module)/MODULE.bazel")
        let module_changed = ($changed | where module == $module)

        if ($module_changed | is-empty) {
            if $base_module_bazel != null and (parse-module-decl $base_module_bazel).version != $version {
                $errors = ($errors | append $"($module): ($name)'s version changed, but nothing else about it did - ($fix)")
            }
            if ($added | is-not-empty) {
                $errors = ($errors | append $"($module): ($name) hasn't changed, but registry/ has new versions of it \(($added | str join ', ')\) - ($fix)")
            }
            continue
        }

        let module_files = $module_changed.0.files
        let files = ($module_files | str join "\n  ")
        let base_version = if $base_module_bazel != null { (parse-module-decl $base_module_bazel).version }
        print $"($module) \(($name)\): ($module_files | length) file\(s) changed, version ($base_version | default 'None') -> ($version)"

        if $version in $released {
            $errors = ($errors | append $"($module): version ($version) of ($name) is already released - ($fix), since these files changed:\n  ($files)")
            continue
        }
        if $base_version != null and $level != null {
            let expected = (bumped $base_version $level)
            if $version != $expected {
                $errors = ($errors | append (
                    $"($module): ($name) should be version ($expected) - a ($level) bump from ($base_version), for the "
                    + $"pull request's title '($title)' - not ($version); ($fix)"
                ))
                continue
            }
        }
        if ($added | where {|v| $v != $version} | is-not-empty) {
            $errors = ($errors | append $"($module): registry/ has new versions of ($name) other than ($version): ($added | str join ', ') - ($fix)")
        }

        let entry = (expected-entry $module)
        let version_dir = ([$REGISTRY_DIR modules $name $version] | path join)
        let actual_source = (git-show $":($version_dir)/source.json")
        if $actual_source == null or $version not-in (registry-versions $name) {
            $errors = ($errors | append $"($module): there's no registry entry for version ($version) of ($name) - ($fix)")
        } else if ($actual_source | from json | to json --raw) != ($entry.source | to json --raw) or (git-show $":($version_dir)/MODULE.bazel") != $entry.module_bazel {
            $errors = ($errors | append (
                $"($module): the registry entry for version ($version) of ($name) \(($version_dir)\) is out of date with "
                + $"($module)/ \(e.g. it changed after the entry was written, or the base branch changed it too - merge "
                + $"it in first) - ($fix)"
            ))
        }
    }
    $errors
}

# --- Releasing ---------------------------------------------------------------

def releasable []: nothing -> list<string> {
    module-dirs | each {|module|
        let decl = (parse-module-decl (open --raw ([$module MODULE.bazel] | path join)))
        if ([$REGISTRY_DIR modules $decl.name $decl.version source.json] | path join | path exists) {
            $"($module) (release-tag $module $decl.version)"
        }
    } | compact
}

# --- Entry point -------------------------------------------------------------

# Paths here are all relative to the repository root, but `bazel run` starts in
# its own runfiles tree - so resolve the caller's paths first, then move to
# the root of the repository they were in.
def invocation-dir []: nothing -> string {
    $env.BUILD_WORKING_DIRECTORY? | default $env.PWD
}

def --env enter-repo-root []: nothing -> nothing {
    cd (invocation-dir)
    cd (git rev-parse --show-toplevel | str trim)
}

# Runs `body`, which returns the errors it found (or nothing), and exits non-zero if there were any.
def run-guarded [body: closure]: nothing -> nothing {
    let errors = (try { do $body | default [] } catch {|e| [$e.msg]})
    for error in $errors {
        if "GITHUB_ACTIONS" in $env {
            # A GitHub annotation - newlines have to be URL-encoded in one.
            print $"::error::($error | str replace --all "\n" '%0A')"
        } else {
            print --stderr $"ERROR: ($error)"
        }
    }
    if ($errors | is-not-empty) {
        exit 1
    }
}

def main []: nothing -> nothing {
    help main
}

# Run in your pull request, after staging your changes: for every module whose
# released contents changed since BASE, sets `module(version = ...)` in its
# MODULE.bazel to the version TITLE implies, writes its registry entry, and
# stages both. Safe to re-run - e.g. after more changes, or a new title - and
# it replaces the registry entries it wrote before.
def "main bump" [
    --title: string # the pull request's (Conventional Commit) title; defaults to the open pull request's title (via `gh`), or else the branch's only commit's subject
    --base: string # git ref being merged into (default: origin/main, or else main)
]: nothing -> nothing {
    run-guarded {
        enter-repo-root
        bump $base $title
        []
    }
}

# What CI runs on every pull request: TITLE must be a Conventional Commit, and
# every module whose released contents changed since BASE must have the
# version it implies and an up-to-date registry entry for it.
def "main check" [
    --title: string # the pull request's (Conventional Commit) title
    --base: string # git ref being merged into, e.g. origin/main
]: nothing -> nothing {
    run-guarded {
        if $title == null or $base == null {
            fail "check needs both --title and --base"
        }
        enter-repo-root
        check $base $title
    }
}

# Writes and stages the registry entry for MODULE's current version, as-is
# (`bump` does this for you).
def "main add" [module: string]: nothing -> nothing {
    run-guarded {
        enter-repo-root
        add-entry $module
        []
    }
}

# Lists `<module> <tag>` for every module whose current version has a
# registry entry - used by release.yml, which releases the ones that aren't
# released yet.
def "main releasable" []: nothing -> nothing {
    run-guarded {
        enter-repo-root
        releasable | each {|line| print $line}
        []
    }
}

# Builds MODULE's release archive - used by release.yml.
def "main archive" [
    module: string
    --out: string # where to write the archive (relative to where you ran this)
    --verify # fail unless it matches the registry entry for MODULE's current version
]: nothing -> nothing {
    run-guarded {
        if $out == null {
            fail "archive needs --out"
        }
        cd (invocation-dir)
        let out = ($out | path expand)
        enter-repo-root
        let integrity = (if $verify { build-archive $module --out $out --verify } else { build-archive $module --out $out })
        print $"Wrote ($out) \(($integrity)\)"
        []
    }
}
