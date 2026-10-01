"""`hugo_binary`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("//:toolchain.bzl", "HugoInfo")

_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))

def _hugo_binary_impl(ctx):
    hugo_info = ctx.toolchains[_TOOLCHAIN_TYPE].hugo_info
    hugo_bin = hugo_info.hugo_bin

    # `DefaultInfo.executable` must be one of this target's own declared
    # outputs - it can't just be the toolchain's own File directly - so this
    # symlinks to the resolved binary rather than copying it. Matches
    # hugo_bin's own extension (".exe" on Windows, none elsewhere), same as
    # the real binary it points at.
    ext = "." + hugo_bin.extension if hugo_bin.extension else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(output = executable, target_file = hugo_bin, is_executable = True)

    return [DefaultInfo(
        executable = executable,
        files = depset([executable]),
        runfiles = ctx.runfiles(files = [hugo_bin]),
    )]

hugo_binary = rule(
    implementation = _hugo_binary_impl,
    executable = True,
    doc = """A directly runnable, hermetic `hugo` binary - resolved via the
    `toolchain_type` toolchain the same way `hugo_build` resolves its own
    tool, so `bazel run //path:name -- <args>` always runs the pinned
    version (`hugo.version(version = ...)`), never whatever (if anything)
    happens to be on the invoking machine's own PATH.

    Mainly useful for `hugo server` (live-reloading local preview - not
    something a hermetic *build* action can meaningfully do, the same
    reasoning `rules_k8s`'s own `kubectl_binary` doc gives for `kubectl`)
    and one-off `hugo` subcommands (`hugo new site`, `hugo mod ...`, ...)
    this module doesn't otherwise wrap. Run it from your site's own
    directory, e.g. `cd path/to/site && bazel run //path:hugo -- server`.
    """,
    attrs = {},
    toolchains = [_TOOLCHAIN_TYPE],
)
