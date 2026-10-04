"""K8s manifest-rendering toolchains: a specific kustomize binary, a specific
helm binary, and a specific kubectl binary.
"""

KustomizeInfo = provider(
    doc = "Information about a specific kustomize binary.",
    fields = {
        "kustomize_bin": "File: the kustomize executable.",
        "version": "String: the kustomize version.",
    },
)

def _kustomize_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            kustomize_info = KustomizeInfo(
                kustomize_bin = ctx.executable.kustomize_bin,
                version = ctx.attr.version,
            ),
        ),
    ]

kustomize_toolchain = rule(
    implementation = _kustomize_toolchain_impl,
    attrs = {
        "kustomize_bin": attr.label(
            executable = True,
            allow_single_file = True,
            cfg = "exec",
            mandatory = True,
        ),
        "version": attr.string(mandatory = True),
    },
)

HelmInfo = provider(
    doc = "Information about a specific helm binary.",
    fields = {
        "helm_bin": "File: the helm executable.",
        "version": "String: the helm version.",
    },
)

def _helm_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            helm_info = HelmInfo(
                helm_bin = ctx.executable.helm_bin,
                version = ctx.attr.version,
            ),
        ),
    ]

helm_toolchain = rule(
    implementation = _helm_toolchain_impl,
    attrs = {
        "helm_bin": attr.label(
            executable = True,
            allow_single_file = True,
            cfg = "exec",
            mandatory = True,
        ),
        "version": attr.string(mandatory = True),
    },
)

KubectlInfo = provider(
    doc = "Information about a specific kubectl binary.",
    fields = {
        "kubectl_bin": "File: the kubectl executable.",
        "version": "String: the kubectl version.",
    },
)

def _kubectl_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            kubectl_info = KubectlInfo(
                kubectl_bin = ctx.executable.kubectl_bin,
                version = ctx.attr.version,
            ),
        ),
    ]

kubectl_toolchain = rule(
    implementation = _kubectl_toolchain_impl,
    attrs = {
        "kubectl_bin": attr.label(
            executable = True,
            allow_single_file = True,
            cfg = "exec",
            mandatory = True,
        ),
        "version": attr.string(mandatory = True),
    },
)
