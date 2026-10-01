# Template for a `terraform_root`'s `bazel run`/`terraform_root_test` entry
# point.
#
# Expanded (via `ctx.actions.expand_template`, substituting the `%{...}%`
# tokens below) into a real, per-target script by `private/root.bzl` - see
# `_terraform_root_impl` - and run by that target's own executable, a
# nu_launcher (see `@rules_nushell//:nu.bzl`: a tiny `/bin/sh` script, or a
# `.bat` on Windows) that runs this with the hermetic, toolchain-resolved
# nu. Not a build action's helper script (unlike private/stage_module.nu and
# private/validate_module.nu, run directly as build actions).
#
# Always hands `bazel run //path:name -- args...` off to another script (see
# SCRIPT_RLOCATION in `main`) once staging/the provider mirror/manifest
# fabrication are set up - this module's own built-in
# `//:default_terraform_script` (auto-init-then-`terraform`) unless
# `root.bzl`'s `_SCRIPT` resolved to something else (a
# `terraform.default_script(target = ...)` request - see extensions.bzl).
#
# Values that come from user-set attributes (`env`, `env_labels`) are
# embedded as raw JSON strings and parsed at runtime, so they round-trip
# exactly whatever characters they contain.

use runfiles.nu

const TF_RLOCATION = "%{tf_rlocation}%"
const STAGING_RLOCATION = "%{staging_rlocation}%"
const MANIFEST_RLOCATION = "%{manifest_rlocation}%"
const SCRIPT_RLOCATION = "%{script_rlocation}%"
const MODULE_RELPATH = "%{module_relpath}%"
const LABEL_KEY = "%{label_key}%"
const TF_LABEL = "%{tf_label}%"
const TF_ROOT_NAME = "%{tf_root_name}%"
const TF_ROOT_PACKAGE = "%{tf_root_package}%"
const TF_VERSION = "%{tf_version}%"

def provider-repr-rlocations []: nothing -> list<string> {
    r###'%{provider_repr_rlocations_json}%'### | from json
}

def extra-env []: nothing -> record {
    r###'%{env_json}%'### | from json
}

def env-label-rlocations []: nothing -> record {
    r###'%{env_labels_json}%'### | from json
}

# See the matching comment in validate_module.nu - one block per independent
# mirror root, `direct` excluded unconditionally so an unmirrored provider
# fails loudly instead of silently trying the network.
def provider-cli-config [mirror_roots: list<string>]: nothing -> string {
    let blocks = ($mirror_roots | each {|root|
        $"\n  filesystem_mirror {\n    path    = \"($root)\"\n    include = [\"*/*/*\"]\n  }"
    } | str join "\n")
    $"\ndisable_checkpoint = true\n\nprovider_installation {\n($blocks)\n  direct {\n    exclude = [\"*/*/*\"]\n  }\n}\n"
}

def build-manifest [entries: list, registry_root: string, staging_root: string]: nothing -> record {
    let modules = ($entries | each {|e|
        let entry = {Key: $e.key, Source: $e.source}
        let entry = if ($e.version | is-not-empty) { $entry | insert Version $e.version } else { $entry }
        if $e.kind == "registry" {
            $entry | insert Dir $"($registry_root)/($e.key)"
        } else {
            $entry | insert Dir $"($staging_root)/($e.own_relpath)"
        }
    })
    {Modules: ([{Key: "", Source: "", Dir: "."}] | append $modules)}
}

# The path up to (not including) its first `component`, or null if it has none.
def path-before [component: string]: string -> any {
    let parts = ($in | path split)
    let index = ($parts | enumerate | where item == $component | get index | first 1)
    if ($index | is-empty) { null } else { $parts | first $index.0 | path join }
}

def is-windows []: nothing -> bool {
    $nu.os-info.name == "windows"
}

# Creates `scratch`'s `bin/` dir, with an entry that runs `tf_bin` under its
# own basename - e.g. `tf_bin` resolving to a `bin_name = "tofu"` build
# makes `bin/tofu` (or `bin/tofu.bat` on Windows, since PATH-based lookup
# there doesn't need the extension typed) - so a script can `PATH`-prepend
# the returned directory and just run `tofu` (or `terraform`, whatever this
# target's `version`/`bin_name` actually resolved to) instead of needing
# `$TF_BIN`.
def make-bin-dir [scratch: string, tf_bin: string]: nothing -> string {
    let bin_dir = ($scratch | path join bin)
    mkdir $bin_dir
    let bin_name = ($tf_bin | path parse | get stem)

    if (is-windows) {
        # No unprivileged symlinks on Windows - a tiny generated wrapper
        # instead. `%*`/`%ERRORLEVEL%` forward args and exit code straight
        # through, so it's transparent to the caller either way.
        $"@echo off\r\n\"($tf_bin)\" %*\r\nexit /b %ERRORLEVEL%\r\n" | save --force ($bin_dir | path join $"($bin_name).bat")
    } else {
        ^ln -s $tf_bin ($bin_dir | path join $bin_name)
    }
    $bin_dir
}

def --wrapped main [...args] {
    let tf_bin = (runfiles rlocation $TF_RLOCATION)
    let staged = (runfiles rlocation $STAGING_RLOCATION)

    # `staged` is read-only and `init`/`plan`/`apply` need to write into the
    # module dir (.terraform/, state, lock file) - copy into a scratch dir
    # kept inside Bazel's own execroot (a sibling of "bazel-out", not /tmp or
    # the real source tree), so `bazel clean` removes it like any other build
    # artifact. Bazel rebuilds execroot's contents on every build/run, so
    # this scratch dir doesn't survive between separate `bazel run`
    # invocations - to compensate, the default script re-runs `init`
    # automatically before any subcommand that needs it.
    let execroot_workspace = ($staged | path-before "bazel-out")
    if $execroot_workspace == null {
        error make {msg: $"Can't find Bazel's execroot from ($staged)"}
    }
    let scratch = ($execroot_workspace | path join rules_terraform_scratch $LABEL_KEY)
    rm --recursive --force $scratch
    mkdir ($scratch | path dirname)
    # `staged` itself may be a runfiles symlink to the (tree artifact)
    # directory - copy what it points at. Not preserving mode means the copy
    # is writable, unlike the (read-only) build output it came from.
    cp --recursive --preserve [] ($staged | path expand) $scratch

    let module_dir = ($scratch | path join $MODULE_RELPATH)

    # Target-declared `env`/`env_labels` (terraform_root's attrs of the same
    # names) always win over whatever the invoking shell already set - meant
    # as fixed config for this target (e.g. TF_LOG, AWS_PROFILE, or a tool's
    # resolved path), not a per-invocation default a caller should be able
    # to shadow. TF_BIN/TF_MODULE_DIR/TF_CLI_CONFIG_FILE below are set after
    # this and always win over both in turn, since those are structural, not
    # user config (root.bzl rejects an `env`/`env_labels` entry using one of
    # those names at analysis time, rather than letting it be silently
    # shadowed here).
    load-env (extra-env)
    load-env (env-label-rlocations | items {|name, rlocation| {name: $name, path: (runfiles rlocation $rlocation)} } | reduce --fold {} {|it, acc| $acc | insert $it.name $it.path })

    let provider_reprs = (provider-repr-rlocations)
    if ($provider_reprs | is-not-empty) {
        let mirror_roots = ($provider_reprs | each {|repr_rlocation|
            let provider_repr = (runfiles rlocation $repr_rlocation)
            [($provider_repr | path-before "providers") providers] | path join
        })
        let cli_config_path = ($scratch | path join .terraformrc)
        provider-cli-config $mirror_roots | save --force $cli_config_path
        $env.TF_CLI_CONFIG_FILE = $cli_config_path
    }

    let manifest_entries = (open (runfiles rlocation $MANIFEST_RLOCATION))
    if ($manifest_entries | is-not-empty) {
        let registry_root = ($scratch | path join $MODULE_RELPATH _registry_modules)
        let modules_dir = ($module_dir | path join .terraform modules)
        mkdir $modules_dir
        build-manifest $manifest_entries $registry_root $scratch | to json --raw | save --force ($modules_dir | path join modules.json)
    }

    # Hand off to whichever script `root.bzl` resolved `_SCRIPT` to - this
    # module's own built-in one by default, or a `terraform.default_script`
    # request - with the same hermetic module dir/binary/provider config this
    # runner itself set up, and let it drive terraform (or anything else)
    # however it wants.
    let script_path = (runfiles rlocation $SCRIPT_RLOCATION)
    if not (is-windows) {
        let mode = (ls --long ($script_path | path expand) | get mode.0)
        if ($mode | str substring 2..2) != "x" {
            error make {msg: $"script ($SCRIPT_RLOCATION): not executable \(chmod +x it\)"}
        }
    }
    $env.TF_BIN = $tf_bin
    $env.TF_MODULE_DIR = $module_dir
    $env.TF_LABEL = $TF_LABEL
    $env.TF_ROOT_NAME = $TF_ROOT_NAME
    $env.TF_ROOT_PACKAGE = $TF_ROOT_PACKAGE
    $env.TF_VERSION = $TF_VERSION
    $env.PATH = ($env.PATH | split row (char esep) | prepend (make-bin-dir $scratch $tf_bin))

    # `bazel run` itself starts this process with cwd set to the target's
    # runfiles tree, not wherever the invoking shell actually was - already
    # synthetic and meaningless to a script author, so there's nothing lost
    # by changing it here: cd into the module dir before handing off, so
    # `$TF_BIN plan` just works without needing a `-chdir=...` flag.
    cd $module_dir
    if (is-windows) {
        # `script_path` may be a `.bat` there, which `exec` can't replace
        # this process with - run it instead; a failing exit code propagates
        # as this script's own.
        ^$script_path ...$args
    } else {
        exec $script_path ...$args
    }
}
