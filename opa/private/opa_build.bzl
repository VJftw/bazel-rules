"""`opa_build`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("//:toolchain.bzl", "OpaInfo")

_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))

def _opa_build_impl(ctx):
    opa_info = ctx.toolchains[_TOOLCHAIN_TYPE].opa_info

    out = ctx.actions.declare_file(ctx.attr.out or ctx.label.name + ".tar.gz")
    root_dir = ctx.files.srcs[0].dirname or "."

    args = ctx.actions.args()
    args.add("build")
    args.add("-b", root_dir)

    # Bazel materializes source inputs to a sandboxed build action as
    # symlinks pointing back at the real source tree (not copies) - `opa
    # build`'s own bundle walker silently skips symlinked files by default
    # (verified empirically: a symlinked policy directory produces a bundle
    # containing only the auto-generated `data.json`/`.manifest`, no `.rego`
    # at all), which `--follow-symlinks` fixes. Bazel's own action sandboxing
    # (explicit `srcs`, no other inputs visible) already provides the
    # isolation a real "don't follow symlinks out of the bundle root" concern
    # would be about, so this is always safe here.
    args.add("--follow-symlinks")
    args.add("-o", out)
    if ctx.attr.revision:
        args.add("--revision", ctx.attr.revision)

    ctx.actions.run(
        outputs = [out],
        inputs = depset(ctx.files.srcs),
        tools = [opa_info.opa_bin],
        executable = opa_info.opa_bin,
        arguments = [args],
        mnemonic = "OpaBuild",
        progress_message = "Building OPA bundle %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([out]))]

opa_build = rule(
    implementation = _opa_build_impl,
    doc = """Packages Rego policies and data files into an OPA bundle
    (a gzipped tarball), as a build action - the resolved `opa_toolchain`
    binary runs `opa build -b <root-dir> --follow-symlinks -o <out>`.

    `srcs[0]` must be a file directly inside the bundle's own root directory
    (the same convention `rules_terraform`'s `terraform_module` uses for its
    own `srcs[0]`) - every other file under that directory, however deeply
    nested, is bundled automatically by `opa build` itself; list them all in
    `srcs` anyway so Bazel knows about them as inputs.
    """,
    attrs = {
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "Every file in the bundle - .rego policies, data.json/data.yaml files, and (if present) a manifest.yaml. srcs[0] must be directly inside the bundle's own root directory.",
        ),
        "revision": attr.string(
            doc = "If set, passed via `--revision` - recorded in the bundle's own `.manifest`.",
        ),
        "out": attr.string(
            doc = "Output filename. Defaults to the target name + '.tar.gz'.",
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)
