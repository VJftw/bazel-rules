"""`k8s_manifests`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("//:manifest.bzl", "K8sManifestInfo")

def _k8s_manifests_impl(ctx):
    manifests = depset(
        direct = ctx.files.srcs,
        transitive = [dep[K8sManifestInfo].manifests for dep in ctx.attr.deps],
    )
    return [
        K8sManifestInfo(manifests = manifests),
        DefaultInfo(files = manifests),
    ]

k8s_manifests = rule(
    implementation = _k8s_manifests_impl,
    doc = """Aggregates plain manifest files (`srcs`) and/or other
    `K8sManifestInfo`-providing targets (`deps` - `helm_template`,
    `kustomize_build`, or another `k8s_manifests`) into one target, the same
    way `plantuml_library` aggregates PlantUML include files in
    rules_plantuml.

    Unlike a plain `filegroup`, a `deps` chain composes transitively - a
    "everything for this environment" bundle built from several smaller
    `k8s_manifests` only needs to be listed once by whatever depends on it,
    rather than every consumer flattening the whole chain into its own
    `deps` by hand. Doesn't merge its inputs into a single file - `srcs`'
    individual files stay individual outputs (`DefaultInfo.files`), so e.g.
    `bazel build //path:all` produces every one of them, and a downstream
    `kubectl apply -f bazel-bin/path/` (or similar) sees them all.
    """,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "This target's own plain manifest files.",
        ),
        "deps": attr.label_list(
            providers = [K8sManifestInfo],
            doc = "Other `K8sManifestInfo`-providing targets (`helm_template`, `kustomize_build`, or another `k8s_manifests`) whose manifests are aggregated in too.",
        ),
    },
)
