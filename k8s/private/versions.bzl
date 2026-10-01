"""Re-exports the checksum mirrors generated for each of this module's three
tools. Not itself generated (unlike the three files it loads from) - kept as
a stable, hand-written single entry point so `extensions.bzl` doesn't need
to know these live in three separate files, one per tool's own mirror
script (see scripts/mirror_kustomize_versions.py, mirror_helm_versions.py,
mirror_kubectl_versions.py) - each only regenerates its own file, so three
independent scripts never race or clobber each other's data.
"""

load("//:private/helm_versions.bzl", _HELM_VERSIONS = "HELM_VERSIONS")
load("//:private/kubectl_versions.bzl", _KUBECTL_VERSIONS = "KUBECTL_VERSIONS")
load("//:private/kustomize_versions.bzl", _KUSTOMIZE_VERSIONS = "KUSTOMIZE_VERSIONS")

KUSTOMIZE_VERSIONS = _KUSTOMIZE_VERSIONS
HELM_VERSIONS = _HELM_VERSIONS
KUBECTL_VERSIONS = _KUBECTL_VERSIONS
