"""`plantuml_library`. Not part of the public API - `//:defs.bzl` re-exports it."""

PlantUMLLibraryInfo = provider(
    doc = "A reusable set of PlantUML include files, plus the transitive files of any `deps`.",
    fields = {
        "transitive_srcs": "depset[File]: this library's own srcs, plus the transitive srcs of every dep.",
    },
)

def _plantuml_library_impl(ctx):
    transitive_srcs = depset(
        direct = ctx.files.srcs,
        transitive = [dep[PlantUMLLibraryInfo].transitive_srcs for dep in ctx.attr.deps],
    )
    return [
        PlantUMLLibraryInfo(transitive_srcs = transitive_srcs),
        DefaultInfo(files = transitive_srcs),
    ]

plantuml_library = rule(
    implementation = _plantuml_library_impl,
    doc = """A reusable set of PlantUML include files (e.g. shared styling/macros,
    `!include`d by one or more `plantuml_diagram` targets), that can itself
    `!include` another `plantuml_library`'s files via `deps`.

    Unlike a plain `filegroup`, a `deps` chain composes transitively - a
    "theme" built from several smaller shared-include libraries only needs
    to be listed once by whatever `plantuml_diagram`/`plantuml_library`
    references it, rather than every consumer having to flatten the whole
    chain into its own `deps` by hand. A `plantuml_diagram`'s own `deps`
    attribute accepts a `plantuml_library` target directly (via its
    `DefaultInfo.files`, already the full transitive set), the same as it
    would a plain file or `filegroup`.
    """,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".puml", ".plantuml", ".pu", ".iuml"],
            doc = "This library's own PlantUML include files.",
        ),
        "deps": attr.label_list(
            providers = [PlantUMLLibraryInfo],
            doc = "Other `plantuml_library` targets this library's own `srcs` reference via `!include`.",
        ),
    },
)
