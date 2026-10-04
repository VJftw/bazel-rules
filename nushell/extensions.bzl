"""Module extension that fetches the `nu` binary and registers it as a toolchain.

Mirrors rules_terraform's/rules_k8s's/rules_opa's/rules_hugo's own
per-platform lazy-fetch design: a `toolchain()` is registered for every
supported platform, but the actual archive is only downloaded for whichever
platform Bazel's toolchain resolution actually selects. Only one version can
be active in a given build, the same as rules_opa/rules_hugo - `nu_binary`/
`nu_test` don't pin a version per target, so the extra config-setting/
transition machinery rules_terraform needs isn't justified here.

Nushell's Linux releases come in both glibc (`-gnu`) and musl (`-musl`)
flavours - the musl ones are fully static, so (like rules_opa's choice of
OPA's `_static` builds) they're the ones used here, as they don't care what
(if any) libc is on the machine running `nu`.
"""

load("//:private/versions.bzl", "NUSHELL_VERSIONS")

_PLATFORMS = {
    "linux_amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64": ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:macos", "@platforms//cpu:arm64"],
    "windows_amd64": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
    "windows_arm64": ["@platforms//os:windows", "@platforms//cpu:arm64"],
}

# Nushell's own Rust target triple for each platform, as used in its release
# asset names.
_TRIPLES = {
    "linux_amd64": "x86_64-unknown-linux-musl",
    "linux_arm64": "aarch64-unknown-linux-musl",
    "darwin_amd64": "x86_64-apple-darwin",
    "darwin_arm64": "aarch64-apple-darwin",
    "windows_amd64": "x86_64-pc-windows-msvc",
    "windows_arm64": "aarch64-pc-windows-msvc",
}

_DEFAULT_URL_TEMPLATE = "https://github.com/nushell/nushell/releases/download/{version}/{asset}"

_TOOLCHAIN_BZL = str(Label("//:toolchain.bzl"))
_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))

def _bin_name(platform):
    return "nu.exe" if platform.startswith("windows_") else "nu"

def _platform_repo_name(platform):
    """The apparent name of the per-platform repo that downloads `platform`'s archive."""
    return "nushell_platform_{}".format(platform)

def _asset_basename(version, platform):
    return "nu-{version}-{triple}".format(version = version, triple = _TRIPLES[platform])

def _asset_name(version, platform):
    ext = "zip" if platform.startswith("windows_") else "tar.gz"
    return "{}.{}".format(_asset_basename(version, platform), ext)

def _nushell_repo_impl(rctx):
    lines = [
        "package(default_visibility = [\"//visibility:public\"])",
        "",
    ]

    for platform, constraints in _PLATFORMS.items():
        repo = _platform_repo_name(platform)
        constraints_str = ", ".join(["\"%s\"" % c for c in constraints])

        lines.append("toolchain(")
        lines.append("    name = \"nu_{}_toolchain\",".format(platform))
        lines.append("    toolchain = \"@{}//:nu_toolchain\",".format(repo))
        lines.append("    toolchain_type = \"{}\",".format(_TOOLCHAIN_TYPE))
        lines.append("    exec_compatible_with = [{}],".format(constraints_str))
        lines.append(")")
        lines.append("")

    rctx.file("BUILD.bazel", "\n".join(lines))

_nushell_repo = repository_rule(
    implementation = _nushell_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
    },
    doc = "Hub repository: registers a toolchain() per supported platform, " +
          "aliasing into the real target living in that platform's own " +
          "repository (see _nushell_platform_repo) - never downloads " +
          "anything itself, so fetching it is always cheap.",
)

def _nushell_platform_repo_impl(rctx):
    platform = rctx.attr.platform
    version = rctx.attr.version
    bin_name = _bin_name(platform)

    asset = _asset_name(version, platform)
    url = (rctx.attr.url_template or _DEFAULT_URL_TEMPLATE).format(version = version, asset = asset)

    # The Linux/macOS `.tar.gz`s wrap everything in a top-level
    # `nu-<version>-<triple>/` directory; the Windows `.zip`s don't.
    strip_prefix = "" if platform.startswith("windows_") else _asset_basename(version, platform)

    rctx.download_and_extract(
        url = url,
        output = ".",
        sha256 = rctx.attr.sha256.get(platform, ""),
        stripPrefix = strip_prefix,
    )

    rctx.file("BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

load("{toolchain_bzl}", "nu_toolchain")

nu_toolchain(
    name = "nu_toolchain",
    nu_bin = "{bin_name}",
    version = "{version}",
)
""".format(toolchain_bzl = _TOOLCHAIN_BZL, bin_name = bin_name, version = version))

_nushell_platform_repo = repository_rule(
    implementation = _nushell_platform_repo_impl,
    attrs = {
        "platform": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "sha256": attr.string_dict(),
        "url_template": attr.string(),
    },
    doc = "Downloads the requested Nushell archive for a single platform. " +
          "One of these is registered per supported platform, but Bazel " +
          "only actually fetches (and only ever runs download_and_extract " +
          "for) the one(s) whose toolchains the current build's toolchain " +
          "resolution selects.",
)

def _version_key(version):
    """Sorts Nushell's plain `major.minor.patch` versions numerically."""
    return [int(part) if part.isdigit() else 0 for part in version.split(".")]

def _nushell_ext_impl(module_ctx):
    # The root module's own request always applies, and it may declare at
    # most one - the same way rules_opa/rules_hugo only honour the root's.
    # Unlike those, though, a non-root module's request isn't ignored: other
    # rulesets (e.g. rules_opa) use Nushell internally, so they each declare
    # the version they need, and when the root module declares none the
    # highest of those applies - so a consumer of such a ruleset never has
    # to know about or configure Nushell at all.
    root_tag = None
    dep_tags = []
    for mod in module_ctx.modules:
        for t in mod.tags.version:
            if mod.is_root:
                if root_tag != None:
                    fail("nushell.version was declared more than once by the root module - only one is allowed.")
                root_tag = t
            else:
                dep_tags.append(t)

    tag = root_tag
    if tag == None:
        for t in dep_tags:
            if tag == None or _version_key(t.version) > _version_key(tag.version):
                tag = t

    if tag == None:
        fail("No nushell.version(...) tag declared by any module - a Nushell version must be requested, e.g. nushell.version(version = \"0.116.0\").")

    # An explicit sha256 always wins, per platform. Otherwise, fall back to
    # the generated mirror in private/versions.bzl (see
    # scripts/mirror_nushell_versions.py) - but only for the default (GitHub
    # release) URL: that mirror's checksums are for Nushell's own official
    # archives specifically, so they'd be meaningless (and wrong) for a
    # version fetched from a `url_template` override.
    defaults = {} if tag.url_template else NUSHELL_VERSIONS.get(tag.version, {})
    sha256 = dict(tag.sha256)
    for platform, digest in defaults.items():
        if platform not in sha256:
            sha256[platform] = digest

    _nushell_repo(name = "nushell", version = tag.version)

    for platform in _PLATFORMS:
        _nushell_platform_repo(
            name = _platform_repo_name(platform),
            platform = platform,
            version = tag.version,
            sha256 = sha256,
            url_template = tag.url_template,
        )

_version_tag = tag_class(
    doc = """Requests the Nushell version to fetch and register as a toolchain.

    Fetched from Nushell's GitHub releases by default (`nushell/nushell`,
    tag `<version>` - Nushell's tags have no leading 'v') - `url_template`
    overrides this. The root module may declare this at most once, and its
    request always wins; if it declares none, the highest version requested
    by any other module (e.g. a ruleset that uses Nushell internally)
    applies instead, along with that request's own `sha256`/`url_template`.
    """,
    attrs = {
        "version": attr.string(mandatory = True, doc = "Nushell version, e.g. '0.116.0'."),
        "sha256": attr.string_dict(
            doc = "Map of platform (e.g. 'linux_amd64') to the release archive's sha256, for supply-chain integrity. Optional for any version already in private/versions.bzl (see scripts/mirror_nushell_versions.py) as long as `url_template` isn't set - otherwise required.",
        ),
        "url_template": attr.string(
            doc = "Override the download URL - a string with literal '{version}'/'{asset}' placeholders ('{asset}' is Nushell's own release filename for the requested version/platform, e.g. 'nu-0.116.0-x86_64-unknown-linux-musl.tar.gz'), substituted via Python-style `.format()`. Defaults to Nushell's own GitHub release URL. Setting this disables the private/versions.bzl mirror default for `sha256` (see above).",
        ),
    },
)

nushell = module_extension(
    implementation = _nushell_ext_impl,
    tag_classes = {"version": _version_tag},
)
