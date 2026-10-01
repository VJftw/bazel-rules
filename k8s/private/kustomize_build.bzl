"""`kustomize_build`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("@rules_nushell//:nu.bzl", "NU_TOOLCHAIN_TYPE", "run_nu")
load("//:manifest.bzl", "K8sManifestInfo")
load("//:toolchain.bzl", "KustomizeInfo")

_TOOLCHAIN_TYPE = str(Label("//:kustomize_toolchain_type"))

def _staging_relpath(file):
    # Like short_path, but without the "../repo/" external-repo prefix - a
    # clean relative path to use inside our own staging directory.
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return file.short_path

def _dirname(path):
    return "/".join(path.split("/")[:-1])

def _join(dir, name):
    return name if dir in ("", ".") else dir + "/" + name

def _single_manifest_file(ctx, key, target):
    if K8sManifestInfo in target:
        files = target[K8sManifestInfo].manifests.to_list()
    else:
        files = target[DefaultInfo].files.to_list()
    if len(files) != 1:
        fail((
            "{label}: resources[\"{key}\"] = {dep} produces {n} files, but " +
            "exactly one is required so it can be staged at a single path - " +
            "point it at a target with one output instead."
        ).format(label = ctx.label, key = key, dep = target.label, n = len(files)))
    return files[0]

def _build_plain(ctx, kustomize_info, out):
    # The common case (no `resources`): run kustomize directly against the
    # real source tree, no staging - see the rule doc for why this is safe
    # and how `bases: [../other]` still resolves.
    kustomization_dir = ctx.file.kustomization.dirname or "."

    args = ctx.actions.args()
    args.add("build", kustomization_dir)
    args.add("--output", out)
    args.add("--load-restrictor", ctx.attr.load_restrictor)

    ctx.actions.run(
        outputs = [out],
        inputs = depset([ctx.file.kustomization] + ctx.files.srcs),
        tools = [kustomize_info.kustomize_bin],
        executable = kustomize_info.kustomize_bin,
        arguments = [args],
        mnemonic = "KustomizeBuild",
        progress_message = "Rendering kustomization %s" % ctx.label,
    )

def _build_staged(ctx, kustomize_info, out):
    # `resources` is set: the whole point is to make an otherwise-generated
    # file (e.g. a helm_template output) resolvable at a literal relative
    # path the *real* kustomization.yaml's own `resources:` (or `patches:`,
    # or a generator's file reference, etc) already names - e.g.
    # `resources: [rendered.yaml]`. That only works, and only means anything
    # (kustomize's own transformers - namespace, labels, patches - only
    # apply to resources declared *within the same kustomization*, verified
    # empirically: stacking the extra file in as a sibling of an unrelated
    # outer kustomization does NOT apply that outer kustomization's own
    # transformers to it), if the file actually exists on disk right next to
    # a writable copy of `kustomization` itself - which means staging the
    # whole closure (kustomization + srcs, preserving their real relative
    # layout so `bases: [../other]` keeps resolving) into one tree, the same
    # way rules_terraform's own `stage_module` does for an unrelated reason
    # (Terraform needing somewhere writable for `.terraform/`).
    closure = [ctx.file.kustomization] + ctx.files.srcs
    pairs = [[f.path, _staging_relpath(f)] for f in closure]

    kustomization_dir = _dirname(_staging_relpath(ctx.file.kustomization))

    resource_files = []
    for key, target in ctx.attr.resources.items():
        f = _single_manifest_file(ctx, key, target)
        resource_files.append(f)
        pairs.append([f.path, _join(kustomization_dir, key)])

    manifest = ctx.actions.declare_file(ctx.label.name + "_stage_manifest.json")
    ctx.actions.write(output = manifest, content = json.encode(pairs))

    staging_dir = ctx.actions.declare_directory(ctx.label.name + "_staged")
    run_nu(
        ctx,
        script = ctx.file._stage_files_nu,
        outputs = [staging_dir],
        inputs = closure + resource_files + [manifest],
        arguments = ["--manifest", manifest.path, "--out", staging_dir.path],
        mnemonic = "KustomizeStage",
        progress_message = "Staging kustomization %s" % ctx.label,
    )

    args = ctx.actions.args()
    args.add("build", _join(staging_dir.path, kustomization_dir))
    args.add("--output", out)
    args.add("--load-restrictor", ctx.attr.load_restrictor)

    ctx.actions.run(
        outputs = [out],
        inputs = [staging_dir],
        tools = [kustomize_info.kustomize_bin],
        executable = kustomize_info.kustomize_bin,
        arguments = [args],
        mnemonic = "KustomizeBuild",
        progress_message = "Rendering kustomization %s" % ctx.label,
    )

def _kustomize_build_impl(ctx):
    kustomize_info = ctx.toolchains[_TOOLCHAIN_TYPE].kustomize_info
    out = ctx.actions.declare_file(ctx.attr.out or ctx.label.name + ".yaml")

    if ctx.attr.resources:
        _build_staged(ctx, kustomize_info, out)
    else:
        _build_plain(ctx, kustomize_info, out)

    return [
        DefaultInfo(files = depset([out])),
        K8sManifestInfo(manifests = depset([out])),
    ]

kustomize_build = rule(
    implementation = _kustomize_build_impl,
    doc = """Renders a kustomization directory into a single merged Kubernetes
    manifest, as a build action - the resolved `kustomize_toolchain` binary
    runs `kustomize build <dir-of-kustomization> --output <out>`.

    `kustomization` must be named exactly `kustomization.yaml`,
    `kustomization.yml`, or `Kustomization` (kustomize's own requirement).
    `srcs` must list every other file `kustomization` (and any `bases` it
    references, however deeply) needs - resources, patches, generators, and
    any base directories' own kustomization files. Bazel build actions run
    against real source-tree-relative paths, so a `bases: [../other]`
    reference resolves correctly as long as that other directory's own files
    are also listed in `srcs` (e.g. via a `filegroup` in the base's own
    package) - no staging into a synthetic tree is needed, UNLESS
    `resources` is set (see below), which switches this to a staged build.

    Returns `K8sManifestInfo` (see `//:manifest.bzl`) alongside the usual
    `DefaultInfo`, so this target's own output can itself be fed into
    another `kustomize_build`'s `resources` - kustomize-of-kustomize
    composes the same way helm-then-kustomize does.
    """,
    attrs = {
        "kustomization": attr.label(
            mandatory = True,
            allow_single_file = ["kustomization.yaml", "kustomization.yml", "Kustomization"],
            doc = "This target's own kustomization file.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Every other file `kustomization` references, directly or (via `bases`) transitively - resources, patches, generators, and any base directories' own kustomization files.",
        ),
        "resources": attr.string_keyed_label_dict(
            allow_files = True,
            doc = "Extra, typically-generated files to make available at a literal path within `kustomization`'s own directory - keyed by that exact relative path, e.g. `{\"rendered.yaml\": \":hello_chart\"}` for a `kustomization.yaml` that itself declares `resources: [rendered.yaml]` (or references that path from `patches:`, a generator, etc). This is how a `helm_template` (or another `kustomize_build`) output gets fed into `kustomize build` such that this target's own transformers (`namespace`, `commonLabels`, patches, ...) actually apply to it - they only apply to resources declared within the same kustomization, not to a file merely staged alongside it some other way. Each value must resolve to exactly one file (via `K8sManifestInfo.manifests` if the target provides it, else `DefaultInfo.files`). Setting this switches the build to a staged copy of `kustomization` + `srcs` (see the rule doc) - leave it unset (the default) to skip staging entirely.",
        ),
        "out": attr.string(
            doc = "Output filename. Defaults to the target name + '.yaml'.",
        ),
        "load_restrictor": attr.string(
            default = "LoadRestrictionsNone",
            values = ["LoadRestrictionsNone", "LoadRestrictionsRootOnly"],
            doc = "Passed through to kustomize's own `--load-restrictor` flag. Defaults to 'LoadRestrictionsNone' rather than kustomize's own default ('LoadRestrictionsRootOnly') - Bazel materializes source inputs as symlinks in the sandbox execroot, which kustomize's RootOnly restrictor refuses to resolve at all (even for the kustomization file itself), breaking under normal Bazel sandboxing. Bazel's own action sandboxing (explicit `srcs`, no other inputs visible) already provides the isolation this flag exists for, so relaxing it here is safe.",
        ),
        "_stage_files_nu": attr.label(default = "//:private/stage_files.nu", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN_TYPE, NU_TOOLCHAIN_TYPE],
)
