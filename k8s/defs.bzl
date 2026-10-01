"""Public API: `kustomize_build` (renders a kustomization directory into a
single merged manifest), `helm_template` (renders a Helm chart into a single
merged manifest), `k8s_manifests` (aggregates manifest files and/or other
`K8sManifestInfo`-providing targets into one target), and `kubectl_binary`
(a directly runnable, hermetic `kubectl`).

The actual rule implementations live under `private/` - this file just wires
up the public names.
"""

load("//:manifest.bzl", _K8sManifestInfo = "K8sManifestInfo")
load("//:private/helm_template.bzl", _helm_template = "helm_template")
load("//:private/k8s_manifests.bzl", _k8s_manifests = "k8s_manifests")
load("//:private/kubectl_binary.bzl", _kubectl_binary = "kubectl_binary")
load("//:private/kustomize_build.bzl", _kustomize_build = "kustomize_build")

K8sManifestInfo = _K8sManifestInfo
kustomize_build = _kustomize_build
helm_template = _helm_template
k8s_manifests = _k8s_manifests
kubectl_binary = _kubectl_binary
