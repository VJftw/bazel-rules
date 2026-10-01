"""Module extension that fetches the `hugo` binary and registers it as a toolchain.

Mirrors rules_terraform's/rules_k8s's/rules_opa's own per-platform
lazy-fetch design: a `toolchain()` is registered for every supported
platform, but the actual archive is only downloaded for whichever platform
Bazel's toolchain resolution actually selects for a given target's exec
platform. Only one version (and one release "variant" - see `_hugo_tag`
below) can be active in a given build, the same as rules_opa/rules_plantuml -
`hugo_build`/`hugo_binary` don't pin a version per target, so the extra
config-setting/transition machinery rules_terraform needs isn't justified
here.

Darwin is a single `darwin_universal` platform, not split into
`darwin_amd64`/`darwin_arm64` the way every other module in this repo splits
Darwin - Hugo ships one universal (fat) binary covering both architectures,
so the registered `toolchain()` has no `@platforms//cpu:...` constraint at
all, matching any Mac regardless of architecture. It's also fetched
differently: Hugo's Darwin releases are a macOS `.pkg` installer, not a
plain `.tar.gz`/`.zip` - see `_fetch_darwin` below and `private/extract_pkg.py`.
"""

load("//:private/versions.bzl", "HUGO_VERSIONS")

_PLATFORMS = {
    "linux_amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64": ["@platforms//os:linux", "@platforms//cpu:arm64"],
    # One universal (fat) binary covers both architectures - see this
    # file's own module docstring.
    "darwin_universal": ["@platforms//os:macos"],
    "windows_amd64": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
    "windows_arm64": ["@platforms//os:windows", "@platforms//cpu:arm64"],
}

# "" (the default, no-infix "hugo" release) is the plain build with no Sass/
# SCSS support; "extended" is what most themes actually expect (adds
# libsass-based Sass/SCSS processing) and is this module's own default;
# "extended_withdeploy"/"withdeploy" additionally bundle `hugo deploy`
# (rsync/S3/GCS/Azure cloud publishing) support. Not every variant publishes
# every platform (verified empirically: "extended" has no windows_arm64
# build) - a platform missing for the requested variant simply never gets a
# `toolchain()` registered for it, the same as any other unavailable
# platform/version combination in this module.
_VARIANT_INFIXES = {
    "hugo": "",
    "extended": "_extended",
    "extended_withdeploy": "_extended_withdeploy",
    "withdeploy": "_withdeploy",
}

_OS_ARCH = {
    "linux_amd64": "linux-amd64",
    "linux_arm64": "linux-arm64",
    "darwin_universal": "darwin-universal",
    "windows_amd64": "windows-amd64",
    "windows_arm64": "windows-arm64",
}

_DEFAULT_URL_TEMPLATE = "https://github.com/gohugoio/hugo/releases/download/v{version}/{asset}"

_TOOLCHAIN_BZL = str(Label("//:toolchain.bzl"))
_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))
_EXTRACT_PKG_PY = Label("//:private/extract_pkg.py")

def _archive_ext(platform):
    if platform == "darwin_universal":
        return "pkg"
    if platform.startswith("windows_"):
        return "zip"
    return "tar.gz"

def _bin_name(platform):
    return "hugo.exe" if platform.startswith("windows_") else "hugo"

def _platform_repo_name(platform):
    """The apparent name of the per-platform repo that downloads `platform`'s archive."""
    return "hugo_platform_{}".format(platform)

def _asset_name(version, variant, platform):
    infix = _VARIANT_INFIXES[variant]
    return "hugo{infix}_{version}_{os_arch}.{ext}".format(
        infix = infix,
        version = version,
        os_arch = _OS_ARCH[platform],
        ext = _archive_ext(platform),
    )

def _fetch_darwin(rctx, url, sha256, bin_name):
    """Downloads Hugo's Darwin `.pkg` and extracts just the `hugo` binary from it.

    Unlike every other platform (a plain `.tar.gz`/`.zip` Bazel's own
    `download_and_extract` understands natively), Hugo's Darwin release is a
    macOS installer package (Apple's XAR container format, wrapping a
    gzip-compressed cpio archive) - see `private/extract_pkg.py`'s own
    module docstring for the full extraction story (a real `pkgutil` on an
    actual Mac, or a pure-Python XAR/gzip parse + a `cpio` shell-out
    otherwise).
    """
    rctx.download(url = url, output = "hugo.pkg", sha256 = sha256)
    python = rctx.which("python3") or rctx.which("python")
    if not python:
        fail("Fetching the Darwin hugo toolchain needs a `python3` (or `python`) interpreter on PATH.")
    script = rctx.path(_EXTRACT_PKG_PY)
    result = rctx.execute([python, script, "--pkg", "hugo.pkg", "--member", "hugo", "--out", bin_name])
    if result.return_code != 0:
        fail("private/extract_pkg.py failed:\n" + result.stdout + result.stderr)

def _hugo_repo_impl(rctx):
    lines = [
        "package(default_visibility = [\"//visibility:public\"])",
        "",
    ]

    for platform, constraints in _PLATFORMS.items():
        repo = _platform_repo_name(platform)
        constraints_str = ", ".join(["\"%s\"" % c for c in constraints])

        lines.append("toolchain(")
        lines.append("    name = \"hugo_{}_toolchain\",".format(platform))
        lines.append("    toolchain = \"@{}//:hugo_toolchain\",".format(repo))
        lines.append("    toolchain_type = \"{}\",".format(_TOOLCHAIN_TYPE))
        lines.append("    exec_compatible_with = [{}],".format(constraints_str))
        lines.append(")")
        lines.append("")

    rctx.file("BUILD.bazel", "\n".join(lines))

_hugo_repo = repository_rule(
    implementation = _hugo_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
    },
    doc = "Hub repository: registers a toolchain() per supported platform, " +
          "aliasing into the real target living in that platform's own " +
          "repository (see _hugo_platform_repo) - never downloads anything " +
          "itself, so fetching it is always cheap.",
)

def _hugo_platform_repo_impl(rctx):
    platform = rctx.attr.platform
    version = rctx.attr.version
    variant = rctx.attr.variant
    bin_name = _bin_name(platform)

    asset = _asset_name(version, variant, platform)
    url = (rctx.attr.url_template or _DEFAULT_URL_TEMPLATE).format(version = version, asset = asset)
    sha256 = rctx.attr.sha256.get(platform, "")

    if platform == "darwin_universal":
        _fetch_darwin(rctx, url, sha256, bin_name)
    else:
        rctx.download_and_extract(url = url, output = ".", sha256 = sha256)

    rctx.file("BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

load("{toolchain_bzl}", "hugo_toolchain")

hugo_toolchain(
    name = "hugo_toolchain",
    hugo_bin = "{bin_name}",
    version = "{version}",
    variant = "{variant}",
)
""".format(toolchain_bzl = _TOOLCHAIN_BZL, bin_name = bin_name, version = version, variant = variant))

_hugo_platform_repo = repository_rule(
    implementation = _hugo_platform_repo_impl,
    attrs = {
        "platform": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "variant": attr.string(mandatory = True),
        "sha256": attr.string_dict(),
        "url_template": attr.string(),
    },
    doc = "Downloads the requested hugo archive/installer for a single " +
          "platform. One of these is registered per supported platform, " +
          "but Bazel only actually fetches (and only ever runs " +
          "download/download_and_extract/the Darwin .pkg extraction for) " +
          "the one whose toolchain the current build's toolchain " +
          "resolution selects.",
)

def _hugo_ext_impl(module_ctx):
    tag = None
    for mod in module_ctx.modules:
        # Only the root module's own request applies, the same way a
        # library dependency can't unilaterally decide what version every
        # consumer's build renders its site with.
        if not mod.is_root:
            continue
        for t in mod.tags.version:
            if tag != None:
                fail("hugo.version was declared more than once - only one is allowed.")
            tag = t

    if tag == None:
        fail("No hugo.version(...) tag declared by the root module - a Hugo version must be requested, e.g. hugo.version(version = \"0.166.0\").")

    if tag.variant not in _VARIANT_INFIXES:
        fail("hugo.version: variant must be one of %s, got %r" % (_VARIANT_INFIXES.keys(), tag.variant))

    # An explicit sha256 always wins, per platform. Otherwise, fall back to
    # the generated mirror in private/versions.bzl (see
    # scripts/mirror_hugo_versions.py) - but only for the default (GitHub
    # release) URL and the default "extended" variant: the mirror only
    # covers that one variant's official checksums, so it'd be meaningless
    # (and wrong) for a `url_template` override or a different `variant`.
    sha256 = dict(tag.sha256)
    if not tag.url_template and tag.variant == "extended":
        for platform, digest in HUGO_VERSIONS.get(tag.version, {}).items():
            if platform not in sha256:
                sha256[platform] = digest

    _hugo_repo(name = "hugo", version = tag.version)

    for platform in _PLATFORMS:
        _hugo_platform_repo(
            name = _platform_repo_name(platform),
            platform = platform,
            version = tag.version,
            variant = tag.variant,
            sha256 = sha256,
            url_template = tag.url_template,
        )

_version_tag = tag_class(
    doc = """Requests the Hugo version (and release variant) to fetch and
    register as a toolchain.

    Fetched from Hugo's GitHub releases by default
    (`gohugoio/hugo`, tag `v<version>`) - `url_template` overrides this.
    Only takes effect from the root module, and only once - declaring it
    more than once (even across separate `bazel_dep`s) is a build error, and
    one from a dependency is silently ignored.
    """,
    attrs = {
        "version": attr.string(mandatory = True, doc = "Hugo version, e.g. '0.166.0' (without the leading 'v')."),
        "variant": attr.string(
            default = "extended",
            values = ["hugo", "extended", "extended_withdeploy", "withdeploy"],
            doc = "Which release build to fetch - 'extended' (the default) adds Sass/SCSS support most themes expect; 'hugo' is the plain build; 'extended_withdeploy'/'withdeploy' additionally bundle `hugo deploy` cloud-publishing support. The generated checksum mirror (see private/versions.bzl) only covers 'extended' - any other variant always needs an explicit `sha256`.",
        ),
        "sha256": attr.string_dict(
            doc = "Map of platform (e.g. 'linux_amd64', 'darwin_universal') to the release archive's sha256, for supply-chain integrity. Optional for the 'extended' variant of any version already in private/versions.bzl (see scripts/mirror_hugo_versions.py) as long as `url_template` isn't set - otherwise required.",
        ),
        "url_template": attr.string(
            doc = "Override the download URL - a string with literal '{version}'/'{asset}' placeholders ('{asset}' is Hugo's own release filename for the requested version/variant/platform, e.g. 'hugo_extended_0.166.0_linux-amd64.tar.gz'), substituted via Python-style `.format()`. Defaults to Hugo's own GitHub release URL. Setting this disables the private/versions.bzl mirror default for `sha256` (see above).",
        ),
    },
)

hugo = module_extension(
    implementation = _hugo_ext_impl,
    tag_classes = {"version": _version_tag},
)
