"""`helm_template`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("@rules_nushell//:nu.bzl", "NU_TOOLCHAIN_TYPE", "run_nu")
load("//:manifest.bzl", "K8sManifestInfo")
load("//:toolchain.bzl", "HelmInfo")

_TOOLCHAIN_TYPE = str(Label("//:helm_toolchain_type"))

def _helm_template_impl(ctx):
    helm_info = ctx.toolchains[_TOOLCHAIN_TYPE].helm_info
    helm_bin = helm_info.helm_bin

    out = ctx.actions.declare_file(ctx.attr.out or ctx.label.name + ".yaml")
    chart_dir = ctx.file.chart_yaml.dirname or "."
    release_name = ctx.attr.release_name or ctx.label.name

    helm_args = ["template", release_name, chart_dir]
    if ctx.attr.namespace:
        helm_args += ["--namespace", ctx.attr.namespace]
    if ctx.attr.include_crds:
        helm_args.append("--include-crds")
    for f in ctx.files.values:
        helm_args += ["-f", f.path]
    for s in ctx.attr.set_values:
        helm_args += ["--set", s]

    # `helm template` only ever writes its rendered manifest to stdout -
    # there's no single-file output flag like kustomize's own `--output` -
    # so this runs it through private/capture_stdout.nu (via the hermetic nu
    # resolved from rules_nushell's toolchain) rather than a
    # `ctx.actions.run_shell` redirection. Keeps the action shell-free on
    # every platform, including Windows.
    run_nu(
        ctx,
        script = ctx.file._capture_stdout_nu,
        outputs = [out],
        inputs = [ctx.file.chart_yaml] + ctx.files.srcs + ctx.files.values,
        tools = [helm_bin],
        arguments = [helm_bin.path, out.path] + helm_args,
        mnemonic = "HelmTemplate",
        progress_message = "Rendering Helm chart %s" % ctx.label,
    )

    return [
        DefaultInfo(files = depset([out])),
        K8sManifestInfo(manifests = depset([out])),
    ]

helm_template = rule(
    implementation = _helm_template_impl,
    doc = """Renders a Helm chart into a single merged Kubernetes manifest, as a
    build action - the resolved `helm_toolchain` binary runs `helm template
    <release_name> <dir-of-chart_yaml> ...`, with stdout captured into `out`.

    `srcs` must list every other file the chart needs - `values.yaml`,
    everything under `templates/`, any vendored subcharts under `charts/`,
    etc. Bazel build actions run against real source-tree-relative paths, so
    no staging into a synthetic tree is needed.

    Returns `K8sManifestInfo` (see `//:manifest.bzl`) alongside the usual
    `DefaultInfo`, so this target's own output can be fed straight into a
    `kustomize_build`'s `resources` - see that rule's own doc.
    """,
    attrs = {
        "chart_yaml": attr.label(
            mandatory = True,
            allow_single_file = ["Chart.yaml"],
            doc = "This chart's own Chart.yaml.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Every other file the chart needs - values.yaml, templates/**, any vendored charts/** subcharts, etc.",
        ),
        "values": attr.label_list(
            allow_files = True,
            doc = "Extra values files, passed via repeated `-f`, in order.",
        ),
        "set_values": attr.string_list(
            doc = "Extra `--set KEY=VALUE` overrides, in order.",
        ),
        "release_name": attr.string(
            doc = "Release name, passed as `helm template`'s positional argument. Defaults to the target name.",
        ),
        "namespace": attr.string(
            doc = "If set, passed via `--namespace`.",
        ),
        "include_crds": attr.bool(
            default = True,
            doc = "Whether to pass `--include-crds`.",
        ),
        "out": attr.string(
            doc = "Output filename. Defaults to the target name + '.yaml'.",
        ),
        "_capture_stdout_nu": attr.label(default = "//:private/capture_stdout.nu", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN_TYPE, NU_TOOLCHAIN_TYPE],
)
