# Copies a `terraform_module`'s transitive srcs + registry files into one
# tree.
#
# Invoked as a build action (via the hermetic nu from rules_nushell's
# toolchain, not a shell) - see `stage_module` in private/common.bzl. All
# paths are plain, already execroot-relative paths; no runfiles resolution is
# needed here (unlike private/terraform_runner_template.nu, which runs later,
# outside the build sandbox).

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
