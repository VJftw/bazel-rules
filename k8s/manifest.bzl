"""K8sManifestInfo: the common provider `helm_template`, `kustomize_build`, and
`k8s_manifests` all return, letting them compose freely - a `helm_template`
target can be fed straight into another `kustomize_build`'s `resources`
(see `private/kustomize_build.bzl`), a `kustomize_build` output can feed a
further `kustomize_build` the same way, and `k8s_manifests` aggregates any
number of these (or plain files) into one target.
"""

K8sManifestInfo = provider(
    doc = "One or more rendered/aggregated Kubernetes manifest files.",
    fields = {
        "manifests": "depset[File]: every rendered/aggregated manifest file.",
    },
)
