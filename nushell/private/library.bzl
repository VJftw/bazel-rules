"""`nu_library`. Not part of the public API - `//:defs.bzl` re-exports it."""

NuLibraryInfo = provider(
    doc = "A reusable set of Nushell modules/scripts, plus the transitive files of any `deps`.",
    fields = {
        "transitive_srcs": "depset[File]: this library's own srcs, plus the transitive srcs of every dep.",
    },
)

def _nu_library_impl(ctx):
    transitive_srcs = depset(
        direct = ctx.files.srcs,
        transitive = [dep[NuLibraryInfo].transitive_srcs for dep in ctx.attr.deps],
    )

    runfiles = ctx.runfiles(transitive_files = transitive_srcs)
    for target in ctx.attr.data + ctx.attr.deps:
        runfiles = runfiles.merge(ctx.runfiles(files = target[DefaultInfo].files.to_list()))
        runfiles = runfiles.merge(target[DefaultInfo].default_runfiles)

    return [
        NuLibraryInfo(transitive_srcs = transitive_srcs),
        DefaultInfo(files = transitive_srcs, runfiles = runfiles),
    ]

nu_library = rule(
    implementation = _nu_library_impl,
    doc = """A reusable set of Nushell modules (or scripts), `use`d/`source`d by
    `nu_binary`/`nu_test` targets and other `nu_library` targets that list it
    in their `deps`.

    A `deps` chain composes transitively - a library built on other
    libraries only needs to be listed once by whatever uses it, rather than
    every consumer flattening the whole chain into its own `deps` by hand
    (the same shape as rules_plantuml's `plantuml_library`).

    Every library's repository root is added to `nu`'s include path
    (`--include-path`) at runtime, so a module can be `use`d either relative
    to the script using it (`use ../lib/greeting.nu`) or relative to the root
    of the repository it lives in (`use lib/greeting.nu`) - see
    `private/nu_runner_template.py`.
    """,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".nu"],
            doc = "This library's own `.nu` files.",
        ),
        "deps": attr.label_list(
            providers = [NuLibraryInfo],
            doc = "Other `nu_library` targets this library's own `srcs` `use`/`source`.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Files this library needs at runtime, available via runfiles to anything that depends on it.",
        ),
    },
)
