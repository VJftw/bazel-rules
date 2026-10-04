"""Module extension that fetches the `opa` binary and registers it as a toolchain.

Mirrors rules_terraform's/rules_k8s's own per-platform lazy-fetch design: a
`toolchain()` is registered for every supported platform, but the actual
binary is only downloaded for whichever platform Bazel's toolchain
resolution actually selects for a given target's exec platform. Simpler than
either of those two, though: OPA publishes a single raw binary per release
(no archive to extract - unlike kustomize/helm, which both ship a `.tar.gz`/
`.zip`), and there's only one tool (unlike rules_k8s's kustomize/helm pair),
so there's no `url_template`-per-tool split and no per-tool "is it even
requested" branching - just one `opa.version(...)` tag, like
`plantuml.version` in rules_plantuml.
"""

load("//:private/versions.bzl", "OPA_VERSIONS")

_PLATFORMS = {
    "linux_amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64": ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:macos", "@platforms//cpu:arm64"],
    # Only amd64: OPA doesn't publish a windows_arm64 build.
    "windows_amd64": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
}

# OPA's own release asset names - not simply "{platform}"-parameterized: the
# Linux builds carry a "_static" suffix (fully static, no libc dependency -
# the more portable choice for a hermetic toolchain, since it doesn't care
# what (if any) libc is on the exec machine), and the Windows build carries
# ".exe"; Darwin gets neither.
_ASSET_NAMES = {
    "linux_amd64": "opa_linux_amd64_static",
    "linux_arm64": "opa_linux_arm64_static",
    "darwin_amd64": "opa_darwin_amd64",
    "darwin_arm64": "opa_darwin_arm64",
    "windows_amd64": "opa_windows_amd64.exe",
}

_DEFAULT_URL_TEMPLATE = "https://github.com/open-policy-agent/opa/releases/download/v{version}/{asset}"

_TOOLCHAIN_BZL = str(Label("//:toolchain.bzl"))
_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))

def _bin_name(platform):
    return "opa.exe" if platform.startswith("windows_") else "opa"

def _platform_repo_name(platform):
    """The apparent name of the per-platform repo that downloads `platform`'s binary."""
    return "opa_platform_{}".format(platform)

def _opa_repo_impl(rctx):
    lines = [
        "package(default_visibility = [\"//visibility:public\"])",
        "",
    ]

    for platform, constraints in _PLATFORMS.items():
        repo = _platform_repo_name(platform)
        constraints_str = ", ".join(["\"%s\"" % c for c in constraints])

        lines.append("toolchain(")
        lines.append("    name = \"opa_{}_toolchain\",".format(platform))
        lines.append("    toolchain = \"@{}//:opa_toolchain\",".format(repo))
        lines.append("    toolchain_type = \"{}\",".format(_TOOLCHAIN_TYPE))
        lines.append("    exec_compatible_with = [{}],".format(constraints_str))
        lines.append(")")
        lines.append("")

    rctx.file("BUILD.bazel", "\n".join(lines))

_opa_repo = repository_rule(
    implementation = _opa_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
    },
    doc = "Hub repository: registers a toolchain() per supported platform, " +
          "aliasing into the real target living in that platform's own " +
          "repository (see _opa_platform_repo) - never downloads anything " +
          "itself, so fetching it is always cheap.",
)

def _opa_platform_repo_impl(rctx):
    platform = rctx.attr.platform
    asset = _ASSET_NAMES[platform]
    url = (rctx.attr.url_template or _DEFAULT_URL_TEMPLATE).format(version = rctx.attr.version, platform = platform, asset = asset)
    bin_name = _bin_name(platform)

    rctx.download(
        url = url,
        output = bin_name,
        sha256 = rctx.attr.sha256.get(platform, ""),
        executable = True,
    )

    rctx.file("BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

load("{toolchain_bzl}", "opa_toolchain")

opa_toolchain(
    name = "opa_toolchain",
    opa_bin = "{bin_name}",
    version = "{version}",
)
""".format(toolchain_bzl = _TOOLCHAIN_BZL, bin_name = bin_name, version = rctx.attr.version))

_opa_platform_repo = repository_rule(
    implementation = _opa_platform_repo_impl,
    attrs = {
        "platform": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "sha256": attr.string_dict(),
        "url_template": attr.string(),
    },
    doc = "Downloads the requested opa binary for a single platform. One of " +
          "these is registered per supported platform, but Bazel only " +
          "actually fetches (and only ever executes download for) the " +
          "one(s) whose toolchains the current build's toolchain " +
          "resolution selects.",
)

def _opa_ext_impl(module_ctx):
    tag = None
    for mod in module_ctx.modules:
        # Only the root module's own request applies, the same way a
        # library dependency can't unilaterally decide what version every
        # consumer's build evaluates policies with.
        if not mod.is_root:
            continue
        for t in mod.tags.version:
            if tag != None:
                fail("opa.version was declared more than once - only one is allowed.")
            tag = t

    if tag == None:
        fail("No opa.version(...) tag declared by the root module - an OPA version must be requested, e.g. opa.version(version = \"1.20.2\").")

    # An explicit sha256 always wins, per platform. Otherwise, fall back to
    # the generated mirror in private/versions.bzl (see
    # scripts/mirror_opa_versions.py) - but only for the default (GitHub
    # release) URL: that mirror's checksums are for OPA's own official
    # binaries specifically, so they'd be meaningless (and wrong) for a
    # version fetched from a `url_template` override.
    defaults = {} if tag.url_template else OPA_VERSIONS.get(tag.version, {})
    sha256 = dict(tag.sha256)
    for platform, digest in defaults.items():
        if platform not in sha256:
            sha256[platform] = digest

    _opa_repo(name = "opa", version = tag.version)

    for platform in _PLATFORMS:
        _opa_platform_repo(
            name = _platform_repo_name(platform),
            platform = platform,
            version = tag.version,
            sha256 = sha256,
            url_template = tag.url_template,
        )

_version_tag = tag_class(
    doc = """Requests the OPA version to fetch and register as a toolchain.

    Fetched from OPA's GitHub releases by default
    (`open-policy-agent/opa`, tag `v<version>`) - `url_template` overrides
    this (a string with literal '{version}'/'{platform}'/'{asset}'
    placeholders, `platform` e.g. 'linux_amd64', `asset` OPA's own
    platform-specific release filename, substituted via Python-style
    `.format()`). Only takes effect from the root module, and only once -
    declaring it more than once (even across separate `bazel_dep`s) is a
    build error, and one from a dependency is silently ignored.
    """,
    attrs = {
        "version": attr.string(mandatory = True, doc = "OPA version, e.g. '1.20.2' (without the leading 'v')."),
        "sha256": attr.string_dict(
            doc = "Map of platform (e.g. 'linux_amd64') to the binary's sha256, for supply-chain integrity. Optional for any 1.x version already in private/versions.bzl (a mirror covering every 1.x release - see scripts/mirror_opa_versions.py) as long as `url_template` isn't set (that mirror is specific to OPA's own official binaries) - otherwise required.",
        ),
        "url_template": attr.string(
            doc = "Override the download URL. Defaults to OPA's own GitHub release URL. Setting this disables the private/versions.bzl mirror default for `sha256` (see above), since that mirror is specific to OPA's own official binaries.",
        ),
    },
)

opa = module_extension(
    implementation = _opa_ext_impl,
    tag_classes = {"version": _version_tag},
)
