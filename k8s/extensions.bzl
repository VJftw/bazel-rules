"""Module extension that fetches kustomize/helm/kubectl binaries and registers them as toolchains.

Mirrors rules_terraform's own per-platform lazy-fetch design (see that
module's extensions.bzl): kustomize, helm, and kubectl all ship as native,
per-platform binaries, so - like Terraform - a `toolchain()` is registered
for every supported platform, but the actual archive/binary is only
downloaded for whichever platform Bazel's toolchain resolution actually
selects for a given target's exec platform. Unlike Terraform, only one
version of each tool can be active in a given build (no `//:version`
build-setting/transition machinery) - `kustomize_build`/`helm_template`/
`kubectl_binary` don't pin a version per target, so that extra complexity
isn't justified here.

`k8s.kustomize(...)`/`k8s.helm(...)`/`k8s.kubectl(...)` are each declared at
most once, and only take effect from the root module - the same way
`plantuml.version` works in rules_plantuml - so a dependency can't
unilaterally change what version the rest of your build renders manifests
(or talks to a cluster) with. None of the three is required - a build that
only uses `kustomize_build` need not declare `k8s.helm(...)`/
`k8s.kubectl(...)` at all, and so on for any combination; the corresponding
toolchain type then simply has nothing registered for it, the same as never
calling `register_toolchains("@k8s//:all")` at all would mean.
"""

load("//:private/versions.bzl", "HELM_VERSIONS", "KUBECTL_VERSIONS", "KUSTOMIZE_VERSIONS")

_PLATFORMS = {
    "linux_amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64": ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:macos", "@platforms//cpu:arm64"],
    # Only amd64: neither project publishes a windows_arm64 build.
    "windows_amd64": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
}

# Both projects publish a .zip for Windows and a .tar.gz everywhere else -
# `rctx.download_and_extract` picks the right extraction method from the URL
# itself, so the only thing that needs to vary is this suffix.
_KUSTOMIZE_URL_TEMPLATE = "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v{version}/kustomize_v{version}_{platform}.{ext}"
_HELM_URL_TEMPLATE = "https://get.helm.sh/helm-v{version}-{platform_dash}.{ext}"

# Unlike kustomize/helm, kubectl publishes a raw binary per platform - no
# archive to extract (`{ext}` is only ".exe" on Windows, appended directly
# to the URL, not a separate archive suffix - see `_kubectl_url`).
_KUBECTL_URL_TEMPLATE = "https://dl.k8s.io/release/v{version}/bin/{os}/{arch}/kubectl{ext}"

_TOOLCHAIN_BZL = str(Label("//:toolchain.bzl"))
_DEFS_BZL = str(Label("//:defs.bzl"))
_KUSTOMIZE_TOOLCHAIN_TYPE = str(Label("//:kustomize_toolchain_type"))
_HELM_TOOLCHAIN_TYPE = str(Label("//:helm_toolchain_type"))
_KUBECTL_TOOLCHAIN_TYPE = str(Label("//:kubectl_toolchain_type"))

def _archive_ext(platform):
    return "zip" if platform.startswith("windows_") else "tar.gz"

def _platform_dash(platform):
    # kustomize's release archives use "linux_amd64" (underscore); helm's use
    # "linux-amd64" (dash) - same platform, different naming convention.
    return platform.replace("_", "-")

def _kubectl_os_arch(platform):
    # kubectl's release URL splits "linux_amd64" into separate path
    # segments ("bin/linux/amd64/kubectl") rather than either of
    # kustomize's/helm's own single-segment conventions.
    os, _, arch = platform.partition("_")
    return os, arch

def _bin_name(bin_name, default, platform):
    base = bin_name or default
    return base + ".exe" if platform.startswith("windows_") else base

def _platform_repo_name(platform):
    """The apparent name of the per-platform repo that downloads `platform`'s archives."""
    return "k8s_platform_{}".format(platform)

def _merge_mirror_sha256(explicit_sha256, url_template, mirror, version):
    """An explicit `sha256` always wins, per platform. Otherwise falls back to `mirror`'s entry for `version` - unless `url_template` is set, since a generated mirror's checksums are for that tool's own official release process specifically, and would be meaningless (and wrong) for a `url_template` override."""
    if url_template:
        return explicit_sha256
    result = dict(explicit_sha256)
    for platform, sha256 in mirror.get(version, {}).items():
        if platform not in result:
            result[platform] = sha256
    return result

def _k8s_repo_impl(rctx):
    lines = [
        "package(default_visibility = [\"//visibility:public\"])",
        "",
    ]

    if rctx.attr.kubectl_version:
        # A ready-to-use instance, so `bazel run @k8s//:kubectl -- <args>`
        # works with zero extra BUILD.bazel wiring beyond declaring
        # `k8s.kubectl(...)` - see kubectl_binary.bzl.
        lines.append("load(\"{defs_bzl}\", \"kubectl_binary\")".format(defs_bzl = _DEFS_BZL))
        lines.append("")
        lines.append("kubectl_binary(name = \"kubectl\")")
        lines.append("")

    for platform, constraints in _PLATFORMS.items():
        repo = _platform_repo_name(platform)
        constraints_str = ", ".join(["\"%s\"" % c for c in constraints])

        if rctx.attr.kustomize_version:
            lines.append("toolchain(")
            lines.append("    name = \"kustomize_{}_toolchain\",".format(platform))
            lines.append("    toolchain = \"@{}//:kustomize_toolchain\",".format(repo))
            lines.append("    toolchain_type = \"{}\",".format(_KUSTOMIZE_TOOLCHAIN_TYPE))
            lines.append("    exec_compatible_with = [{}],".format(constraints_str))
            lines.append(")")
            lines.append("")

        if rctx.attr.helm_version:
            lines.append("toolchain(")
            lines.append("    name = \"helm_{}_toolchain\",".format(platform))
            lines.append("    toolchain = \"@{}//:helm_toolchain\",".format(repo))
            lines.append("    toolchain_type = \"{}\",".format(_HELM_TOOLCHAIN_TYPE))
            lines.append("    exec_compatible_with = [{}],".format(constraints_str))
            lines.append(")")
            lines.append("")

        if rctx.attr.kubectl_version:
            lines.append("toolchain(")
            lines.append("    name = \"kubectl_{}_toolchain\",".format(platform))
            lines.append("    toolchain = \"@{}//:kubectl_toolchain\",".format(repo))
            lines.append("    toolchain_type = \"{}\",".format(_KUBECTL_TOOLCHAIN_TYPE))
            lines.append("    exec_compatible_with = [{}],".format(constraints_str))
            lines.append(")")
            lines.append("")

    rctx.file("BUILD.bazel", "\n".join(lines))

_k8s_repo = repository_rule(
    implementation = _k8s_repo_impl,
    attrs = {
        "kustomize_version": attr.string(),
        "helm_version": attr.string(),
        "kubectl_version": attr.string(),
    },
    doc = "Hub repository: registers a toolchain() per supported platform for " +
          "each requested tool, aliasing into the real target living in that " +
          "platform's own repository (see _k8s_platform_repo), plus a ready-to-run " +
          "`:kubectl` kubectl_binary instance if requested - never downloads an " +
          "archive/binary itself, so fetching it is always cheap.",
)

def _k8s_platform_repo_impl(rctx):
    platform = rctx.attr.platform
    lines = [
        "package(default_visibility = [\"//visibility:public\"])",
        "",
        "load(\"{toolchain_bzl}\", \"kustomize_toolchain\", \"helm_toolchain\", \"kubectl_toolchain\")".format(toolchain_bzl = _TOOLCHAIN_BZL),
        "",
    ]

    if rctx.attr.kustomize_version:
        ext = _archive_ext(platform)
        url = (rctx.attr.kustomize_url_template or _KUSTOMIZE_URL_TEMPLATE).format(
            version = rctx.attr.kustomize_version,
            platform = platform,
            ext = ext,
        )
        rctx.download_and_extract(
            url = url,
            output = "kustomize",
            sha256 = rctx.attr.kustomize_sha256.get(platform, ""),
        )
        bin_name = _bin_name(rctx.attr.kustomize_bin_name, "kustomize", platform)
        lines.append("kustomize_toolchain(")
        lines.append("    name = \"kustomize_toolchain\",")
        lines.append("    kustomize_bin = \"kustomize/{}\",".format(bin_name))
        lines.append("    version = \"{}\",".format(rctx.attr.kustomize_version))
        lines.append(")")
        lines.append("")

    if rctx.attr.helm_version:
        ext = _archive_ext(platform)
        platform_dash = _platform_dash(platform)
        url = (rctx.attr.helm_url_template or _HELM_URL_TEMPLATE).format(
            version = rctx.attr.helm_version,
            platform_dash = platform_dash,
            ext = ext,
        )
        rctx.download_and_extract(
            url = url,
            output = "helm",
            sha256 = rctx.attr.helm_sha256.get(platform, ""),
        )
        bin_name = _bin_name(rctx.attr.helm_bin_name, "helm", platform)
        lines.append("helm_toolchain(")
        lines.append("    name = \"helm_toolchain\",")
        lines.append("    helm_bin = \"helm/{}/{}\",".format(platform_dash, bin_name))
        lines.append("    version = \"{}\",".format(rctx.attr.helm_version))
        lines.append(")")
        lines.append("")

    if rctx.attr.kubectl_version:
        os_, arch = _kubectl_os_arch(platform)
        ext = ".exe" if platform.startswith("windows_") else ""
        url = (rctx.attr.kubectl_url_template or _KUBECTL_URL_TEMPLATE).format(
            version = rctx.attr.kubectl_version,
            os = os_,
            arch = arch,
            ext = ext,
        )
        bin_name = _bin_name(rctx.attr.kubectl_bin_name, "kubectl", platform)

        # No archive to extract - kubectl publishes the raw binary itself
        # (unlike kustomize/helm's .tar.gz/.zip), so a plain `rctx.download`
        # writes it straight to `bin_name`, executable bit set directly.
        rctx.download(
            url = url,
            output = bin_name,
            sha256 = rctx.attr.kubectl_sha256.get(platform, ""),
            executable = True,
        )
        lines.append("kubectl_toolchain(")
        lines.append("    name = \"kubectl_toolchain\",")
        lines.append("    kubectl_bin = \"{}\",".format(bin_name))
        lines.append("    version = \"{}\",".format(rctx.attr.kubectl_version))
        lines.append(")")
        lines.append("")

    rctx.file("BUILD.bazel", "\n".join(lines))

_k8s_platform_repo = repository_rule(
    implementation = _k8s_platform_repo_impl,
    attrs = {
        "platform": attr.string(mandatory = True),
        "kustomize_version": attr.string(),
        "kustomize_sha256": attr.string_dict(),
        "kustomize_url_template": attr.string(),
        "kustomize_bin_name": attr.string(),
        "helm_version": attr.string(),
        "helm_sha256": attr.string_dict(),
        "helm_url_template": attr.string(),
        "helm_bin_name": attr.string(),
        "kubectl_version": attr.string(),
        "kubectl_sha256": attr.string_dict(),
        "kubectl_url_template": attr.string(),
        "kubectl_bin_name": attr.string(),
    },
    doc = "Downloads the requested kustomize/helm archives and kubectl binary for " +
          "a single platform. One of these is registered per supported platform, " +
          "but Bazel only actually fetches (and only ever executes " +
          "download/download_and_extract for) the one(s) whose toolchains the " +
          "current build's toolchain resolution selects.",
)

def _k8s_ext_impl(module_ctx):
    kustomize_tag = None
    helm_tag = None
    kubectl_tag = None

    for mod in module_ctx.modules:
        # Only the root module's own request applies, the same way a
        # library dependency can't unilaterally decide what version every
        # consumer's build renders manifests with.
        if not mod.is_root:
            continue
        for t in mod.tags.kustomize:
            if kustomize_tag != None:
                fail("k8s.kustomize was declared more than once - only one is allowed.")
            kustomize_tag = t
        for t in mod.tags.helm:
            if helm_tag != None:
                fail("k8s.helm was declared more than once - only one is allowed.")
            helm_tag = t
        for t in mod.tags.kubectl:
            if kubectl_tag != None:
                fail("k8s.kubectl was declared more than once - only one is allowed.")
            kubectl_tag = t

    kustomize_version = kustomize_tag.version if kustomize_tag else ""
    kustomize_url_template = kustomize_tag.url_template if kustomize_tag else ""
    kustomize_bin_name = kustomize_tag.bin_name if kustomize_tag else ""
    kustomize_sha256 = _merge_mirror_sha256(
        kustomize_tag.sha256 if kustomize_tag else {},
        kustomize_url_template,
        KUSTOMIZE_VERSIONS,
        kustomize_version,
    )

    helm_version = helm_tag.version if helm_tag else ""
    helm_url_template = helm_tag.url_template if helm_tag else ""
    helm_bin_name = helm_tag.bin_name if helm_tag else ""
    helm_sha256 = _merge_mirror_sha256(
        helm_tag.sha256 if helm_tag else {},
        helm_url_template,
        HELM_VERSIONS,
        helm_version,
    )

    kubectl_version = kubectl_tag.version if kubectl_tag else ""
    kubectl_url_template = kubectl_tag.url_template if kubectl_tag else ""
    kubectl_bin_name = kubectl_tag.bin_name if kubectl_tag else ""
    kubectl_sha256 = _merge_mirror_sha256(
        kubectl_tag.sha256 if kubectl_tag else {},
        kubectl_url_template,
        KUBECTL_VERSIONS,
        kubectl_version,
    )

    _k8s_repo(
        name = "k8s",
        kustomize_version = kustomize_version,
        helm_version = helm_version,
        kubectl_version = kubectl_version,
    )

    for platform in _PLATFORMS:
        _k8s_platform_repo(
            name = _platform_repo_name(platform),
            platform = platform,
            kustomize_version = kustomize_version,
            kustomize_sha256 = kustomize_sha256,
            kustomize_url_template = kustomize_url_template,
            kustomize_bin_name = kustomize_bin_name,
            helm_version = helm_version,
            helm_sha256 = helm_sha256,
            helm_url_template = helm_url_template,
            helm_bin_name = helm_bin_name,
            kubectl_version = kubectl_version,
            kubectl_sha256 = kubectl_sha256,
            kubectl_url_template = kubectl_url_template,
            kubectl_bin_name = kubectl_bin_name,
        )

_kustomize_tag = tag_class(
    doc = """Requests the kustomize version to fetch and register as a toolchain.

    Fetched from kustomize's GitHub releases by default
    (`kubernetes-sigs/kustomize`, tag `kustomize/v<version>`) - `url_template`
    overrides this. Only takes effect from the root module, and only once -
    declaring it more than once (even across separate `bazel_dep`s) is a
    build error, and one from a dependency is silently ignored.
    """,
    attrs = {
        "version": attr.string(mandatory = True, doc = "kustomize version, e.g. '5.8.1' (without the leading 'v')."),
        "sha256": attr.string_dict(
            doc = "Map of platform (e.g. 'linux_amd64') to the release archive's sha256, for supply-chain integrity. Optional for any 5.x version already in private/kustomize_versions.bzl (a mirror covering every 5.x release - see scripts/mirror_kustomize_versions.py) as long as `url_template` isn't set (that mirror is specific to kustomize's own official release process) - otherwise required.",
        ),
        "url_template": attr.string(
            doc = "Override the download URL - a string with literal '{version}'/'{platform}'/'{ext}' placeholders ('{platform}' e.g. 'linux_amd64', '{ext}' 'tar.gz' or 'zip' on Windows), substituted via Python-style `.format()`. Defaults to kustomize's own GitHub release URL. Setting this disables the private/kustomize_versions.bzl mirror default for `sha256` (see above), since that mirror is specific to kustomize's own official release process.",
        ),
        "bin_name": attr.string(
            doc = "Override the executable's name inside the downloaded archive. Defaults to 'kustomize' ('kustomize.exe' on Windows, and '<bin_name>.exe' on Windows if this is set).",
        ),
    },
)

_helm_tag = tag_class(
    doc = """Requests the helm version to fetch and register as a toolchain.

    Fetched from `get.helm.sh` by default - `url_template` overrides this.
    Only takes effect from the root module, and only once - declaring it
    more than once (even across separate `bazel_dep`s) is a build error, and
    one from a dependency is silently ignored.
    """,
    attrs = {
        "version": attr.string(mandatory = True, doc = "helm version, e.g. '3.22.0' (without the leading 'v')."),
        "sha256": attr.string_dict(
            doc = "Map of platform (e.g. 'linux_amd64') to the release archive's sha256, for supply-chain integrity. Optional for any 3.x version already in private/helm_versions.bzl (a GPG-verified mirror covering every 3.x release - see scripts/mirror_helm_versions.py) as long as `url_template` isn't set (that mirror is specific to Helm's own official release process) - otherwise required.",
        ),
        "url_template": attr.string(
            doc = "Override the download URL - a string with literal '{version}'/'{platform_dash}'/'{ext}' placeholders ('{platform_dash}' e.g. 'linux-amd64', '{ext}' 'tar.gz' or 'zip' on Windows), substituted via Python-style `.format()`. Defaults to helm's own `get.helm.sh` release URL. Setting this disables the private/helm_versions.bzl mirror default for `sha256` (see above), since that mirror is specific to Helm's own official release process.",
        ),
        "bin_name": attr.string(
            doc = "Override the executable's name inside the downloaded archive. Defaults to 'helm' ('helm.exe' on Windows, and '<bin_name>.exe' on Windows if this is set).",
        ),
    },
)

_kubectl_tag = tag_class(
    doc = """Requests the kubectl version to fetch and register as a toolchain.

    Fetched from `dl.k8s.io` by default (`https://dl.k8s.io/release/v<version>/bin/<os>/<arch>/kubectl`
    - see https://kubernetes.io/releases/download/#binaries for the full
    matrix) - `url_template` overrides this. Only takes effect from the root
    module, and only once - declaring it more than once (even across
    separate `bazel_dep`s) is a build error, and one from a dependency is
    silently ignored.

    Registering this also generates a ready-to-run `@k8s//:kubectl`
    (`kubectl_binary`) target - see kubectl_binary.bzl.
    """,
    attrs = {
        "version": attr.string(mandatory = True, doc = "kubectl version, e.g. '1.37.1' (without the leading 'v') - see https://dl.k8s.io/release/stable.txt for the latest."),
        "sha256": attr.string_dict(
            doc = "Map of platform (e.g. 'linux_amd64') to the binary's sha256, for supply-chain integrity. Optional for any 1.x version already in private/kubectl_versions.bzl (a mirror covering every 1.x release - see scripts/mirror_kubectl_versions.py) as long as `url_template` isn't set (that mirror is specific to kubectl's own official binaries) - otherwise required.",
        ),
        "url_template": attr.string(
            doc = "Override the download URL - a string with literal '{version}'/'{os}'/'{arch}'/'{ext}' placeholders ('{os}'/'{arch}' e.g. 'linux'/'amd64' - unlike kustomize's/helm's own single '{platform}'/'{platform_dash}' placeholder, kubectl's own URL scheme splits these into separate path segments; '{ext}' is '.exe' on Windows, appended directly to the binary name, not a separate archive suffix), substituted via Python-style `.format()`. Defaults to kubectl's own `dl.k8s.io` release URL. Setting this disables the private/kubectl_versions.bzl mirror default for `sha256` (see above), since that mirror is specific to kubectl's own official binaries.",
        ),
        "bin_name": attr.string(
            doc = "Override the downloaded binary's own local filename. Defaults to 'kubectl' ('kubectl.exe' on Windows, and '<bin_name>.exe' on Windows if this is set).",
        ),
    },
)

k8s = module_extension(
    implementation = _k8s_ext_impl,
    tag_classes = {"kustomize": _kustomize_tag, "helm": _helm_tag, "kubectl": _kubectl_tag},
)
