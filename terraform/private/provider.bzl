"""`terraform.provider` tag handling for the `terraform` module extension.

Resolves requested provider plugins into downloaded archives, unpacked into a
per-platform Terraform filesystem-mirror directory tree, each wrapped by its
own `terraform_provider_mirror_toolchain` in that platform's own repository -
lazily fetched only for whichever platform Bazel's toolchain resolution
actually selects - and aliased from the hub repo's `toolchain()` targets. See
extensions.bzl.
"""

_PROVIDER_HOSTNAME = "registry.terraform.io"

_DEFAULT_PROVIDER_URL_TEMPLATE = "https://releases.hashicorp.com/terraform-provider-{name}/{version}/terraform-provider-{name}_{version}_{platform}.zip"

def _provider_download_url(url_template, namespace, name, version, platform):
    return (url_template or _DEFAULT_PROVIDER_URL_TEMPLATE).format(
        namespace = namespace,
        name = name,
        version = version,
        platform = platform,
    )

def collect_provider_tags(mod, provider_sources, provider_versions, provider_sha256s, provider_url_templates, seen_providers):
    """Accumulates one module's `.provider()` tags into the extension's shared state.

    Mutates `provider_sources`/`provider_versions`/`provider_sha256s`/
    `provider_url_templates`/`seen_providers` in place.

    Args:
      mod: one `module_ctx.modules` entry, whose `.tags.provider` are consumed.
      provider_sources: list of requested "<namespace>/<name>" source strings,
        appended to in place.
      provider_versions: list of requested versions, parallel to
        `provider_sources`, appended to in place.
      provider_sha256s: dict of "{source}@{version}_{platform}" to sha256,
        filled in place.
      provider_url_templates: dict of "{source}@{version}" to `url_template`
        override, filled in place.
      seen_providers: dict of "{source}@{version}" already added, used to
        de-duplicate repeated tags across modules; filled in place.
    """
    for tag in mod.tags.provider:
        key = "{}@{}".format(tag.source, tag.version)
        if key not in seen_providers:
            seen_providers[key] = True
            provider_sources.append(tag.source)
            provider_versions.append(tag.version)
        for platform, sha256 in tag.sha256.items():
            provider_sha256s["{}@{}_{}".format(tag.source, tag.version, platform)] = sha256
        if tag.url_template:
            provider_url_templates[key] = tag.url_template

def generate_provider_mirror_aliases(lines, platforms, provider_toolchain_type, platform_repo_name):
    """Appends the hub repo's per-platform provider-mirror `toolchain()` targets to `lines`.

    One per platform, each pointing at the real `terraform_provider_mirror_toolchain`
    living in that platform's own repository (see `download_provider_mirror`),
    gated by `exec_compatible_with` so Bazel's toolchain resolution picks the
    mirror matching whatever exec platform is resolving the terraform binary
    toolchain for the same target - and so only that one platform's provider
    archives ever get downloaded.

    Args:
      lines: the hub repo's generated BUILD.bazel content, appended to in place.
      platforms: dict of platform name (e.g. 'linux_amd64') to its
        `exec_compatible_with` constraints.
      provider_toolchain_type: canonical label string of the
        `provider_toolchain_type` these toolchains register against.
      platform_repo_name: function `platform -> str` giving the apparent repo
        name of that platform's per-platform repository.
    """
    for platform, constraints in platforms.items():
        constraints_str = ", ".join(["\"%s\"" % c for c in constraints])

        lines.append("toolchain(")
        lines.append("    name = \"provider_mirror_{}_toolchain\",".format(platform))
        lines.append("    toolchain = \"@{repo}//:provider_mirror\",".format(repo = platform_repo_name(platform)))
        lines.append("    toolchain_type = \"{provider_toolchain_type}\",".format(provider_toolchain_type = provider_toolchain_type))
        lines.append("    exec_compatible_with = [{constraints}],".format(constraints = constraints_str))
        lines.append(")")
        lines.append("")

def download_provider_mirror(rctx, lines, platform):
    """Downloads every requested provider plugin's archive for `platform` only.

    Appends the real `terraform_provider_mirror_toolchain` BUILD.bazel target
    to `lines`. Runs in the per-platform repo that a hub `toolchain()` alias
    (see `generate_provider_mirror_aliases`) points at - so this only
    executes, and only downloads this one platform's provider archives, once
    Bazel's toolchain resolution actually selects a toolchain living in this
    repo.

    Args:
      rctx: the per-platform `repository_ctx`, whose `provider_sources`/
        `provider_versions`/`provider_sha256s`/`provider_url_templates` attrs
        carry every requested provider's metadata (for every platform - this
        function picks out just `platform`'s archives).
      lines: the per-platform repo's generated BUILD.bazel content, appended
        to in place.
      platform: the single platform (e.g. 'linux_amd64') this repo is for.
    """
    for i, source in enumerate(rctx.attr.provider_sources):
        version = rctx.attr.provider_versions[i]
        namespace, _, name = source.rpartition("/")
        url_template = rctx.attr.provider_url_templates.get("{}@{}".format(source, version), "")
        if namespace != "hashicorp" and not url_template:
            fail((
                "terraform.provider only supports HashiCorp-published providers " +
                "(source 'hashicorp/<name>', fetched from releases.hashicorp.com) " +
                "without an explicit `url_template`; got source = '{}'. Third-party/" +
                "community providers aren't resolvable via the full Terraform " +
                "registry protocol (which this extension doesn't implement) - set " +
                "`url_template` to fetch this provider from its own release URL instead."
            ).format(source))

        out_dir = "providers/{hostname}/{namespace}/{name}/{version}/{platform}".format(
            hostname = _PROVIDER_HOSTNAME,
            namespace = namespace,
            name = name,
            version = version,
            platform = platform,
        )
        sha256 = rctx.attr.provider_sha256s.get("{}@{}_{}".format(source, version, platform), "")

        rctx.download_and_extract(
            url = _provider_download_url(url_template, namespace, name, version, platform),
            output = out_dir,
            sha256 = sha256,
        )

    lines.append("terraform_provider_mirror_toolchain(")
    lines.append("    name = \"provider_mirror\",")
    lines.append("    providers = glob([\"providers/**\"], allow_empty = True),")
    lines.append(")")
    lines.append("")

provider_tag = tag_class(
    doc = """Requests a Terraform provider plugin be made available in the offline
    provider mirror.

    By default this fetches HashiCorp's own provider release
    (`releases.hashicorp.com/terraform-provider-<name>/<version>/
    terraform-provider-<name>_<version>_<platform>.zip`), which only works for
    `source = "hashicorp/<name>"`. `url_template` lets you point this at a
    third-party/community provider's own release URL instead, e.g. Cloudflare's:

        terraform.provider(
            source = "cloudflare/cloudflare",
            version = "5.24.0",
            url_template = "https://github.com/cloudflare/terraform-provider-cloudflare/releases/download/v{version}/terraform-provider-cloudflare_{version}_{platform}.zip",
            sha256 = {...},  # required - there's no checksum mirror for providers
        )

    This doesn't call the Terraform Registry API to resolve a download
    location dynamically - you supply the concrete URL template yourself,
    resolved once against the provider's actual release page.
    """,
    attrs = {
        "source": attr.string(
            mandatory = True,
            doc = "Provider source address, e.g. 'hashicorp/aws' or 'cloudflare/cloudflare' (implies registry.terraform.io). Only the 'hashicorp/<name>' namespace can be fetched without `url_template`.",
        ),
        "version": attr.string(mandatory = True, doc = "Provider version, e.g. '6.0.0'."),
        "sha256": attr.string_dict(
            doc = "Map of platform (e.g. 'linux_amd64') to the release archive's sha256, for supply-chain integrity.",
        ),
        "url_template": attr.string(
            doc = "Override the download URL, for a non-HashiCorp (third-party/community) provider. A string with literal '{namespace}', '{name}', '{version}', and '{platform}' placeholders (platform is e.g. 'linux_amd64') - substituted via Python-style `.format()`. Defaults to HashiCorp's own release URL, which only resolves for the 'hashicorp' namespace - required for any other namespace.",
        ),
    },
)
