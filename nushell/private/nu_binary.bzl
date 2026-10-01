"""`nu_binary` and `nu_test`. Not part of the public API - `//:defs.bzl` re-exports them."""

load("//:nu.bzl", "NU_LAUNCHER_ATTRS", "NU_TOOLCHAIN_TYPE", "nu_launcher", "rlocation_path")
load("//:private/library.bzl", "NuLibraryInfo")

_RUNNER_TEMPLATE = Label("//:private/nu_runner_template.nu")

def _repo_relative_path(rlocation):
    # An rlocation path is "<repo>/<path within that repo>".
    return rlocation.partition("/")[2]

def _nu_executable_impl(ctx):
    src = ctx.file.src

    lib_srcs = depset(transitive = [dep[NuLibraryInfo].transitive_srcs for dep in ctx.attr.deps])

    # Every file whose repository root should be on `nu`'s include path - see
    # the runner template for how each is turned into a directory at runtime.
    include_rlocations = []
    for f in [src] + lib_srcs.to_list():
        rlocation = rlocation_path(ctx, f)
        include_rlocations.append([rlocation, _repo_relative_path(rlocation)])

    runner = ctx.actions.declare_file(ctx.label.name + "_runner.nu")
    ctx.actions.expand_template(
        template = ctx.file._runner_template,
        output = runner,
        substitutions = {
            "%{src_rlocation}%": rlocation_path(ctx, src),
            "%{runfiles_lib_rlocation}%": rlocation_path(ctx, ctx.file._nu_runfiles_lib),
            "%{include_rlocations_json}%": json.encode(include_rlocations),
        },
    )

    launcher = nu_launcher(ctx, runner)

    runfiles = launcher.runfiles.merge(ctx.runfiles(
        files = [src] + ctx.files.data,
        transitive_files = lib_srcs,
    ))
    for target in ctx.attr.deps + ctx.attr.data:
        runfiles = runfiles.merge(target[DefaultInfo].default_runfiles)

    return [DefaultInfo(executable = launcher.executable, runfiles = runfiles)]

_ATTRS = {
    "src": attr.label(
        mandatory = True,
        allow_single_file = [".nu"],
        doc = "The Nushell script to run. Any `def main [...]` it defines is called with this target's own arguments, the same as `nu <src> <args...>`.",
    ),
    "deps": attr.label_list(
        providers = [NuLibraryInfo],
        doc = "`nu_library` targets `src` `use`s/`source`s.",
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = "Files `src` needs at runtime, available via runfiles.",
    ),
    "_runner_template": attr.label(default = _RUNNER_TEMPLATE, allow_single_file = True),
} | NU_LAUNCHER_ATTRS

nu_binary = rule(
    implementation = _nu_executable_impl,
    executable = True,
    doc = """A Nushell script, run with the resolved `nu_toolchain`'s pinned
    `nu` - never whatever (if anything) happens to be on the invoking
    machine's own PATH - via `bazel run //path:name -- <args...>`.

    Runs `nu --no-config-file <src> <args...>`, so a script behaves the same
    regardless of the invoking user's own Nushell config. As with any `bazel
    run`, the working directory is this target's runfiles tree - use
    `$env.BUILD_WORKING_DIRECTORY` for the directory `bazel run` was invoked
    from. `src` can also `use runfiles.nu` and resolve any runfile with
    `runfiles rlocation "<repo>/<path>"`.
    """,
    attrs = _ATTRS,
    toolchains = [NU_TOOLCHAIN_TYPE],
)

nu_test = rule(
    implementation = _nu_executable_impl,
    test = True,
    doc = """A Nushell script run as a real `bazel test` - passes iff `nu
    --no-config-file <src> <args...>` exits 0. An uncaught error (e.g. a
    failed `assert` from Nushell's own `std/assert` module) fails it.

    `bazel test` sandboxes execution with no network access by default
    (unless the test opts in via `tags = ["requires-network"]`), so a
    passing `nu_test` also confirms the whole toolchain resolution + runfiles
    pipeline works without ever reaching the network.
    """,
    attrs = _ATTRS,
    toolchains = [NU_TOOLCHAIN_TYPE],
)
