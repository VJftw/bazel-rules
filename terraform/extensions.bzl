"""Module extension that fetches Terraform versions and provider plugins.

Unlike a "one external repo per version/provider" setup, every requested
Terraform version, and every requested provider plugin, is addressable
through the single `@terraform` hub repository generated here - but none of
it is actually downloaded into that hub. Real archives live in one
`@terraform_platform_<platform>` repository per supported platform, and
Bazel's lazy external-repo fetching means a given invocation only ever
downloads the platform(s) its build graph's exec platform(s) actually need,
not all five - see private/version.bzl and private/provider.bzl.

- Each (version, platform) gets a `terraform_toolchain`, living in that
  platform's own repository, aliased from a `toolchain()` in the hub that's
  gated on the requested Terraform version via `target_settings` against the
  `//:version` build setting (see BUILD.bazel and defs.bzl) and on the exec
  platform via `exec_compatible_with`. Bazel's normal toolchain resolution
  picks the one matching `toolchain()` for a given `terraform_root` target,
  which is what triggers that one platform repo's fetch. `windows_amd64` is
  one of the supported platforms (the fetched binary is `terraform.exe`, not
  `terraform`) - see the README's Windows section for what that assumes. See
  private/version.bzl for the `.version()` tag and the binary-fetching logic
  behind it.
- Every requested provider plugin gets unpacked into its platform's own
  Terraform filesystem-mirror directory tree (`providers/<hostname>/<namespace>/
  <type>/<version>/<os_arch>/...`, holding just that one `<os_arch>`), wrapped
  by a `terraform_provider_mirror_toolchain` in that platform's repository,
  aliased from a `toolchain()` in the hub gated by `exec_compatible_with` the
  same way as the binary toolchain above (so the two resolve to the same
  platform for a given target). See private/provider.bzl for the
  `.provider()` tag and the provider-fetching logic behind it.
- Every requested third-party (registry/git) module is downloaded from an
  explicit, pinned archive URL (not resolved dynamically via the Terraform
  Registry API) into `modules/<name>/`, wrapped by one `terraform_registry_module`
  target each. `terraform_module`/`terraform_root`'s `registry_modules` attr
  references these, so their content can be spliced straight into a `.terraform/
  modules/modules.json` manifest at stage time - see defs.bzl - letting `init`
  skip the network for them entirely. Modules aren't platform-specific, so
  unlike versions/providers these live directly in the hub.
"""

load("//:private/provider.bzl", "collect_provider_tags", "download_provider_mirror", "generate_provider_mirror_aliases", "provider_tag")
load("//:private/version.bzl", "collect_version_tags", "download_version_toolchain", "generate_version_toolchain_aliases", "version_tag")

_PLATFORMS = {
    "linux_amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64": ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:macos", "@platforms//cpu:arm64"],
    # Windows toolchains assume a bash (Git for Windows/MSYS2) is on PATH -
    # see the README's Windows section. Only amd64: HashiCorp doesn't publish
    # a windows_arm64 terraform build.
    "windows_amd64": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
}

# Canonical (repo-mapping-independent) labels for the targets in this module
# that the generated hub repository's BUILD.bazel needs to reference. Computed
# here - inside the rules_terraform module - so they resolve correctly no
# matter what name a consumer gives this module via bazel_dep(repo_name=...).
_TOOLCHAIN_BZL = str(Label("//:toolchain.bzl"))
_REGISTRY_MODULE_BZL = str(Label("//:registry_module.bzl"))
_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))
_PROVIDER_TOOLCHAIN_TYPE = str(Label("//:provider_toolchain_type"))
_VERSION_FLAG = str(Label("//:version"))
_DEFAULT_TERRAFORM_SCRIPT = str(Label("//:private/default_terraform_script.py"))

def _platform_repo_name(platform):
    """The apparent name of the per-platform repo that downloads `platform`'s archives."""
    return "terraform_platform_{}".format(platform)

def _terraform_repo_impl(rctx):
    lines = [
        "package(default_visibility = [\"//visibility:public\"])",
        "",
        "load(\"{registry_module_bzl}\", \"terraform_registry_module\")".format(registry_module_bzl = _REGISTRY_MODULE_BZL),
        "",
    ]

    generate_version_toolchain_aliases(lines, rctx.attr.versions, _PLATFORMS, _TOOLCHAIN_TYPE, _VERSION_FLAG, _platform_repo_name)
    generate_provider_mirror_aliases(lines, _PLATFORMS, _PROVIDER_TOOLCHAIN_TYPE, _platform_repo_name)

    # `terraform_root`'s (hidden, non-overridable) script attr defaults to
    # `@terraform//:default_script` (see root.bzl) - an `alias` to whatever
    # `terraform.default_script(target = ...)` requested, or (if no such tag
    # was declared) this module's own built-in auto-init-then-`terraform`
    # script.
    lines.append("alias(name = \"default_script\", actual = \"{}\")".format(rctx.attr.default_script or _DEFAULT_TERRAFORM_SCRIPT))
    lines.append("")

    for i, name in enumerate(rctx.attr.module_names):
        out_dir = "modules/{}".format(name)
        rctx.download_and_extract(
            url = rctx.attr.module_urls[i],
            output = out_dir,
            sha256 = rctx.attr.module_sha256s[i],
            stripPrefix = rctx.attr.module_strip_prefixes[i],
        )

        nested_entries = []
        prefix = name + "."
        for combined_key, other_name in rctx.attr.module_nested.items():
            if combined_key.startswith(prefix):
                call_name = combined_key[len(prefix):]
                nested_entries.append("\"{}\": \":module_{}\"".format(call_name, other_name))

        lines.append("terraform_registry_module(")
        lines.append("    name = \"module_{}\",".format(name))
        lines.append("    srcs = glob([\"{}/**\"], allow_empty = True),".format(out_dir))
        lines.append("    root = \"{}\",".format(out_dir))
        lines.append("    source = \"{}\",".format(rctx.attr.module_sources[i]))
        if rctx.attr.module_versions[i]:
            lines.append("    version = \"{}\",".format(rctx.attr.module_versions[i]))
        if nested_entries:
            lines.append("    nested = {" + ", ".join(nested_entries) + "},")
        lines.append(")")
        lines.append("")

    rctx.file("BUILD.bazel", "\n".join(lines))

_terraform_repo = repository_rule(
    implementation = _terraform_repo_impl,
    attrs = {
        "versions": attr.string_list(mandatory = True),
        "module_names": attr.string_list(),
        "module_sources": attr.string_list(),
        "module_versions": attr.string_list(),
        "module_urls": attr.string_list(),
        "module_sha256s": attr.string_list(),
        "module_strip_prefixes": attr.string_list(),
        "module_nested": attr.string_dict(),
        "default_script": attr.string(doc = "Canonical label string (`str(Label(...))`) of the root module's `terraform.default_script(target = ...)` request, or \"\" if none was declared."),
    },
    doc = "Hub repository: aliases every requested Terraform version/platform's " +
          "toolchain and every platform's provider mirror toolchain to the real " +
          "targets in their per-platform repository (see _terraform_platform_repo), " +
          "and downloads the requested third-party modules directly (not " +
          "platform-specific). Never downloads a version/provider archive itself, " +
          "so fetching it is always cheap - only whichever per-platform repo " +
          "toolchain resolution actually selects gets fetched.",
)

def _terraform_platform_repo_impl(rctx):
    lines = [
        "package(default_visibility = [\"//visibility:public\"])",
        "",
        "load(\"{toolchain_bzl}\", \"terraform_toolchain\", \"terraform_provider_mirror_toolchain\")".format(toolchain_bzl = _TOOLCHAIN_BZL),
        "",
    ]

    download_version_toolchain(rctx, lines, rctx.attr.platform)
    download_provider_mirror(rctx, lines, rctx.attr.platform)

    rctx.file("BUILD.bazel", "\n".join(lines))

_terraform_platform_repo = repository_rule(
    implementation = _terraform_platform_repo_impl,
    attrs = {
        "platform": attr.string(mandatory = True),
        "versions": attr.string_list(mandatory = True),
        "sha256s": attr.string_dict(),
        "version_url_templates": attr.string_dict(),
        "version_bin_names": attr.string_dict(),
        "provider_sources": attr.string_list(),
        "provider_versions": attr.string_list(),
        "provider_sha256s": attr.string_dict(),
        "provider_url_templates": attr.string_dict(),
    },
    doc = "Downloads every requested Terraform version and provider plugin archive " +
          "for a single platform. One of these is registered per supported " +
          "platform, but Bazel only actually fetches (and only ever executes " +
          "download_and_extract for) the one(s) whose toolchains the current " +
          "build's toolchain resolution selects.",
)

def _terraform_ext_impl(module_ctx):
    versions = []
    sha256s = {}
    version_url_templates = {}
    version_bin_names = {}

    provider_sources = []
    provider_versions = []
    provider_sha256s = {}
    provider_url_templates = {}
    seen_providers = {}

    module_names = []
    module_sources = []
    module_versions = []
    module_urls = []
    module_sha256s = []
    module_strip_prefixes = []
    module_nested = {}
    seen_modules = {}

    default_script = ""

    for mod in module_ctx.modules:
        collect_version_tags(mod, _PLATFORMS, versions, sha256s, version_url_templates, version_bin_names)
        collect_provider_tags(mod, provider_sources, provider_versions, provider_sha256s, provider_url_templates, seen_providers)

        # A workspace-wide default, unlike versions/providers/modules (which
        # are additive across the whole dependency graph) - so only the root
        # module's own request applies, the same way a library dependency
        # can't unilaterally change what its consumers' builds default to.
        # Silently ignored (not an error) from a non-root module, so a
        # dependency declaring one doesn't break consumers that don't expect
        # it.
        if mod.is_root:
            for tag in mod.tags.default_script:
                if default_script:
                    fail("terraform.default_script was declared more than once - only one is allowed.")
                default_script = str(tag.target)

        for tag in mod.tags.module:
            if tag.name in seen_modules:
                fail("terraform.module name '{}' registered more than once - names must be unique.".format(tag.name))
            seen_modules[tag.name] = True
            module_names.append(tag.name)
            module_sources.append(tag.source)
            module_versions.append(tag.version)
            module_urls.append(tag.url)
            module_sha256s.append(tag.sha256)
            module_strip_prefixes.append(tag.strip_prefix)
            for call_name, other_name in tag.nested.items():
                module_nested["{}.{}".format(tag.name, call_name)] = other_name

    _terraform_repo(
        name = "terraform",
        versions = versions,
        module_names = module_names,
        module_sources = module_sources,
        module_versions = module_versions,
        module_urls = module_urls,
        module_sha256s = module_sha256s,
        module_strip_prefixes = module_strip_prefixes,
        module_nested = module_nested,
        default_script = default_script,
    )

    for platform in _PLATFORMS:
        _terraform_platform_repo(
            name = _platform_repo_name(platform),
            platform = platform,
            versions = versions,
            sha256s = sha256s,
            version_url_templates = version_url_templates,
            version_bin_names = version_bin_names,
            provider_sources = provider_sources,
            provider_versions = provider_versions,
            provider_sha256s = provider_sha256s,
            provider_url_templates = provider_url_templates,
        )

_module_tag = tag_class(
    doc = """Requests a hermetically fetched third-party Terraform module, to be
    referenced from a `terraform_module`/`terraform_root`'s `registry_modules`
    attribute. Its content is spliced into the consuming module's `.terraform/
    modules/modules.json` manifest at stage time, so `terraform init` never
    needs to resolve it over the network.

    Unlike `.provider()`, this doesn't call the Terraform Registry API to
    resolve a download location - you supply `url` (and `sha256`) directly,
    the same way `.version()`/`.provider()` do. For a registry module, resolve
    that URL once yourself, e.g.:

        curl -sD - https://registry.terraform.io/v1/modules/<namespace>/<name>/<provider>/<version>/download

    which returns an `X-Terraform-Get` header. For a GitHub-backed module that
    resolves to a `git::https://github.com/<owner>/<repo>?ref=<ref>` address,
    the equivalent downloadable archive is
    `https://github.com/<owner>/<repo>/archive/<ref>.tar.gz` (strip_prefix
    `<repo>-<ref>`).

    If this module's own vendored `.tf` files internally reference a further
    third-party module (that the extension can't discover on its own, since
    it never parses `.tf` content), register that one too with its own
    `.module()` tag, then reference it here via `nested`.
    """,
    attrs = {
        "name": attr.string(mandatory = True, doc = "A short, unique label for this fetch, e.g. 'vpc'. Only used to name the generated target/output directory."),
        "source": attr.string(
            mandatory = True,
            doc = "The module source address exactly as Terraform's manifest would record it, e.g. 'registry.terraform.io/cloudposse/label/null' for a registry module (note the required 'registry.terraform.io/' prefix, even though the .tf file's own `source` can omit it), or a 'git::...' address.",
        ),
        "version": attr.string(doc = "The resolved module version, for registry sources. Leave unset for unversioned sources (e.g. a git ref)."),
        "url": attr.string(mandatory = True, doc = "A concrete, directly downloadable archive URL for this module's content."),
        "sha256": attr.string(doc = "The archive's sha256, for supply-chain integrity."),
        "strip_prefix": attr.string(doc = "Directory prefix to strip from the extracted archive, e.g. a GitHub archive's '<repo>-<ref>/' top-level directory."),
        "nested": attr.string_dict(
            doc = "Other `terraform.module`-registered modules THIS module's own vendored `.tf` files reference internally, keyed by the local module call name used inside this module's own source, valued by the other module's `name` (as given to its own `.module()` tag).",
        ),
    },
)

_default_script_tag = tag_class(
    doc = """Sets what `bazel run //path:name -- args...` hands off to for every
    `terraform_root` in the build (see `root.bzl`), instead of this module's
    own built-in default (auto-`init` before `plan`/`apply`/etc, then exec
    `terraform` itself - i.e. what happens if this tag is never declared).
    There's no per-target override - every `terraform_root` in the build
    uses whichever one this resolves to.

    Declared at most once, and only takes effect from the root module - a
    dependency declaring this would otherwise silently change what every
    `terraform_root` in the whole build does.
    """,
    attrs = {
        "target": attr.label(
            mandatory = True,
            doc = "Executable target (e.g. `sh_binary`, `py_binary`) or a plain checked-in script with its executable bit set, to use as every terraform_root's `script`, in place of this module's built-in auto-init-then-`terraform` one. An executable target may bundle any number of files in `DefaultInfo.files` (its `DefaultInfo.executable` is what's actually run); a non-executable target must resolve to exactly one file, since there'd otherwise be no single file to mean.",
        ),
    },
)

terraform = module_extension(
    implementation = _terraform_ext_impl,
    tag_classes = {"version": version_tag, "provider": provider_tag, "module": _module_tag, "default_script": _default_script_tag},
)
