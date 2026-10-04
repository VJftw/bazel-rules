"""`hugo_build`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("@rules_nushell//:nu.bzl", "NU_TOOLCHAIN_TYPE", "run_nu")
load("//:toolchain.bzl", "HugoInfo")

_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))

def _staging_relpath(file):
    # Like short_path, but without the "../repo/" external-repo prefix - a
    # clean relative path to use inside our own staging directory.
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return file.short_path

def _hugo_build_impl(ctx):
    hugo_info = ctx.toolchains[_TOOLCHAIN_TYPE].hugo_info
    hugo_bin = hugo_info.hugo_bin

    # Unlike kustomize_build/helm_template/opa_build (which either work
    # directly against symlinked source-tree paths, or just need one extra
    # flag to cope with them), hugo's own content/layouts walkers silently
    # skip symlinked files entirely - verified empirically: a symlinked
    # `layouts/` or `content/` tree produces a site missing pages that build
    # correctly from real files, with no error or warning, and there's no
    # `--follow-symlinks`-equivalent flag to fix it.
    #
    # The obvious fix is to stage (copy, dereferencing symlinks) `config` +
    # `srcs` into a writable tree in one action, then run hugo against that
    # tree in a second action - the same shape kustomize_build's own staging
    # uses. That does NOT work for hugo specifically, though (verified
    # empirically): Bazel always exposes one action's outputs to a *second,
    # dependent* action's sandbox as symlinks back into the first action's
    # own output location, regardless of whether the first action wrote real
    # copies or not - so the staged tree is symlinked all over again by the
    # time hugo (running in the second action) sees it, reintroducing
    # exactly the problem staging was meant to solve. Copying and running
    # hugo have to happen inside the *same* action - see run_hugo.nu, which
    # does both.
    closure = [ctx.file.config] + ctx.files.srcs
    pairs = [[f.path, _staging_relpath(f)] for f in closure]

    manifest = ctx.actions.declare_file(ctx.label.name + "_stage_manifest.json")
    ctx.actions.write(output = manifest, content = json.encode(pairs))

    out = ctx.actions.declare_directory(ctx.attr.out or ctx.label.name)

    args = ctx.actions.args()
    if ctx.attr.base_url:
        args.add("--baseURL", ctx.attr.base_url)
    if ctx.attr.environment:
        args.add("--environment", ctx.attr.environment)
    if ctx.attr.minify:
        args.add("--minify")
    args.add_all(ctx.attr.extra_args)

    run_nu(
        ctx,
        script = ctx.file._run_hugo_nu,
        outputs = [out],
        inputs = closure + [manifest],
        tools = [hugo_bin],
        arguments = [
            manifest.path,
            ctx.label.name + "_scratch",
            _staging_relpath(ctx.file.config),
            hugo_bin.path,
            out.path,
            args,
        ],
        mnemonic = "HugoBuild",
        progress_message = "Building Hugo site %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([out]))]

hugo_build = rule(
    implementation = _hugo_build_impl,
    doc = """Renders a Hugo site into a directory of static files, as a single
    build action - a small Python wrapper copies `config` + `srcs` into a
    local scratch directory (dereferencing symlinks) and then runs the
    resolved `hugo_toolchain` binary against that copy: `hugo --source
    <scratch dir> --destination <out> --noBuildLock ...`.

    The copy and the `hugo` invocation happen in the same action - see the
    comment on the implementation for why (hugo's own directory walkers
    don't handle Bazel's symlinked source inputs the way kustomize's/opa's
    do, and a separate prior staging action doesn't avoid that either).
    """,
    attrs = {
        "config": attr.label(
            mandatory = True,
            allow_single_file = [".toml", ".yaml", ".yml", ".json"],
            doc = "This site's root Hugo config file (hugo.toml/hugo.yaml/hugo.json, or the legacy config.toml/config.yaml/config.json name) - its own directory becomes the site's `--source` root.",
        ),
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "Every other file the site needs - content/, layouts/, static/, assets/, data/, i18n/, archetypes/, etc.",
        ),
        "base_url": attr.string(
            doc = "Passed via `--baseURL`.",
        ),
        "environment": attr.string(
            default = "production",
            doc = "Passed via `--environment` (selects environment-specific config overlays, e.g. `config/production/...`) - hugo's own CLI default for a plain build (as opposed to `hugo server`, which defaults to 'development') is already 'production'; set explicitly here so a build's output doesn't silently depend on an ambient `HUGO_ENVIRONMENT` env var instead.",
        ),
        "minify": attr.bool(
            default = False,
            doc = "Whether to pass `--minify`.",
        ),
        "extra_args": attr.string_list(
            doc = "Extra flags passed through to `hugo`, e.g. '--gc' or '--cleanDestinationDir'.",
        ),
        "out": attr.string(
            doc = "Output directory name. Defaults to the target name.",
        ),
        "_run_hugo_nu": attr.label(default = "//:private/run_hugo.nu", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN_TYPE, NU_TOOLCHAIN_TYPE],
)
