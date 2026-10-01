# Template for a `nu_binary`'s/`nu_test`'s entry point.
#
# Expanded (via `ctx.actions.expand_template`, substituting the `%{...}%`
# tokens below) by nu_binary.bzl, and run by the target's nu_launcher (see
# //:nu.bzl). Resolves `src` via runfiles, then runs `nu --no-config-file
# --include-path <dirs> <src> <args...>` with the same nu, propagating its
# exit code.
#
# The include path holds the root of every repository that `src` or one of
# its `nu_library` deps lives in, as seen at runtime, so a module can be
# `use`d relative to the root of its own repository (e.g. `use
# lib/greeting.nu`), not just relative to the script using it. Each root is
# derived from a file's resolved path minus its own path within that
# repository, which works the same whether runfiles are a symlink tree (the
# root is then `<runfiles>/<repo>`) or only a manifest (the root is then
# wherever that repository's files really live, e.g. the source tree). The
# directory holding `runfiles.nu` is included too, so `src` can `use
# runfiles.nu` itself.

use runfiles.nu

const SRC_RLOCATION = "%{src_rlocation}%"
const RUNFILES_LIB_RLOCATION = "%{runfiles_lib_rlocation}%"

def include-dirs []: nothing -> list<string> {
    # [rlocation, path within its repository] pairs, embedded as raw JSON.
    let include_rlocations = (r###'%{include_rlocations_json}%'### | from json)
    let roots = ($include_rlocations | each {|pair|
        let resolved = (runfiles rlocation $pair.0 | path expand --no-symlink)
        let suffix = ($pair.1 | path split)
        let parts = ($resolved | path split)
        let root_len = (($parts | length) - ($suffix | length))
        if $root_len > 0 and ($parts | skip $root_len) == $suffix {
            $parts | first $root_len | path join
        }
    })
    let lib_dir = (runfiles rlocation $RUNFILES_LIB_RLOCATION | path expand --no-symlink | path dirname)
    $roots | append $lib_dir | uniq
}

def --wrapped main [...args] {
    let src = (runfiles rlocation $SRC_RLOCATION)
    let nu_args = [
        --no-config-file
        --include-path (include-dirs | str join (char record_sep))
        $src
        ...$args
    ]

    if $nu.os-info.name == "windows" {
        # A failing external command's exit code propagates as this
        # script's own.
        ^$nu.current-exe ...$nu_args
    } else {
        exec $nu.current-exe ...$nu_args
    }
}
