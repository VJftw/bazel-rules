# Copies a manifest's worth of [src, dest] file pairs into one tree.
#
# Invoked as a build action (via the hermetic nu from rules_nushell's
# toolchain, not a shell) - see kustomize_build.bzl's staging path. All
# paths are plain, already execroot-relative paths. Generic (no
# kustomize-specific logic) - mirrors rules_terraform's own
# private/stage_module.nu.

def main [
    --manifest: string  # JSON file: list of [src, dest] pairs, dest relative to --out.
    --out: string  # Output directory (a declare_directory tree artifact).
] {
    for pair in (open $manifest) {
        let dest = ($out | path join $pair.1)
        mkdir ($dest | path dirname)
        # Follows symlinks (Bazel's inputs usually are), and doesn't carry
        # over the source's (read-only) mode.
        cp --preserve [] $pair.0 $dest
    }
}
