"""`terraform_module`. Not part of the public API - `//:defs.bzl` re-exports it."""

load(
    "//:private/common.bzl",
    "COMMON_ATTRS",
    "PROVIDER_TOOLCHAIN_TYPE",
    "PY_TOOLCHAIN_TYPE",
    "TOOLCHAIN_TYPE",
    "TerraformModuleInfo",
    "VERSION_TRANSITION",
    "collect_manifest_entries",
    "collect_provider_mirror_sources",
    "collect_registry_files",
    "collect_transitive_srcs",
    "stage_module",
    "validate_action",
)

def _terraform_module_impl(ctx):
    toolchain_info = ctx.toolchains[TOOLCHAIN_TYPE].terraform_info
    toolchain_provider_files = ctx.toolchains[PROVIDER_TOOLCHAIN_TYPE].provider_mirror_info.files
    provider_mirror_sources = collect_provider_mirror_sources(ctx, toolchain_provider_files)
    transitive_srcs = collect_transitive_srcs(ctx)
    registry_files = collect_registry_files(ctx)
    manifest_entries = collect_manifest_entries(ctx)
    staging_dir, module_relpath = stage_module(ctx, transitive_srcs, registry_files)
    marker = validate_action(ctx, staging_dir, module_relpath, toolchain_info.terraform_bin, provider_mirror_sources, manifest_entries)

    return [
        TerraformModuleInfo(
            transitive_srcs = transitive_srcs,
            own_relpath = module_relpath,
            manifest_entries = manifest_entries,
            registry_files = registry_files,
        ),
        DefaultInfo(files = depset([marker])),
    ]

terraform_module = rule(
    implementation = _terraform_module_impl,
    cfg = VERSION_TRANSITION,
    doc = """A Terraform module: collects its own files plus its `deps`' files, and
    runs `terraform init && terraform validate` against them as a build action,
    using an offline filesystem mirror of every provider plugin requested via
    the `terraform` module extension's `.provider()` tag. The action points
    `-chdir` at a staged tree of the files (see `stage_module` in
    private/common.bzl), never the real source directory.

    Building this target (directly, or transitively as another module's
    `deps`) validates it, using its own pinned `version` - independent of
    whatever `terraform_root` (if any) depends on it. That's mainly so this
    target can be built standalone without having to pass
    `--@rules_terraform//:version` on the command line; it's fine for a
    module's `version` to differ from a dependent `terraform_root`'s.
    """,
    attrs = COMMON_ATTRS,
    toolchains = [TOOLCHAIN_TYPE, PROVIDER_TOOLCHAIN_TYPE, PY_TOOLCHAIN_TYPE],
)
