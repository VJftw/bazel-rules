# Copies a Hugo site's files into a local scratch directory, dereferencing
# symlinks, then runs `hugo` against that copy.
#
# The copy has to happen in the *same* action as the `hugo` invocation, not
# a separate prior "staging" action (see hugo_build.bzl for the full story) -
# Bazel always exposes an action's inputs to any *other* action that depends
# on them as symlinks, even when the producing action itself wrote real,
# independent files; only a copy made and consumed within one single action
# ever stays real. The source and destination are both resolved to absolute
# paths before invoking hugo, sidestepping hugo's own "relative
# `--destination` is resolved against `--source`, not the process's cwd"
# behavior (also documented in hugo_build.bzl) entirely, rather than
# replicating Bazel's own relative-path math for it.
#
# Every argument after the fixed ones below is one of hugo's own flags
# (e.g. --environment, --minify), passed through as-is.

def --wrapped main [
    manifest: string  # JSON file: list of [src, dest] pairs, dest relative to `scratch`.
    scratch: string  # Local scratch directory (not a Bazel-declared output) to copy the site's files into.
    config_dest: string  # The config file's own `manifest` dest - its dirname (relative to `scratch`) becomes hugo's --source root.
    hugo_bin: string
    destination: string
    ...hugo_args
] {
    for pair in (open $manifest) {
        let dest = ($scratch | path join $pair.1)
        mkdir ($dest | path dirname)
        # Follows symlinks - the whole point, see above.
        cp --preserve [] $pair.0 $dest
    }

    let config_dir = ($config_dest | path dirname)
    let source_dir = (if $config_dir == "" { $scratch } else { $scratch | path join $config_dir } | path expand)
    let destination_dir = ($destination | path expand)
    mkdir $destination_dir

    ^($hugo_bin | path expand) --source $source_dir --destination $destination_dir --noBuildLock ...$hugo_args
}
