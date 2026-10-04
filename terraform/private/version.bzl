"""`terraform.version` tag handling for the `terraform` module extension.

Resolves requested Terraform versions into downloaded archives, each
`terraform_toolchain` living in its own per-platform repository - lazily
fetched only for whichever platform Bazel's toolchain resolution actually
selects for a given target's exec platform - and aliased from the hub repo's
`config_setting`/`toolchain()` targets, which gate selection on both the
requested Terraform version (via the `//:version` build setting) and the exec
platform. See extensions.bzl.
"""

load("//:private/versions.bzl", "TERRAFORM_VERSIONS")

_DEFAULT_URL_TEMPLATE = "https://releases.hashicorp.com/terraform/{version}/terraform_{version}_{platform}.zip"

def _terraform_download_url(url_template, version, platform):
    return (url_template or _DEFAULT_URL_TEMPLATE).format(version = version, platform = platform)

def _terraform_bin_name(bin_name, platform):
    base = bin_name or "terraform"
    return base + ".exe" if platform.startswith("windows_") else base

def collect_version_tags(mod, platforms, versions, sha256s, version_url_templates, version_bin_names):
    """Accumulates one module's `.version()` tags into the extension's shared state.

    Mutates `versions`/`sha256s`/`version_url_templates`/`version_bin_names` in place.

    Args:
      mod: one `module_ctx.modules` entry, whose `.tags.version` are consumed.
      platforms: dict of platform name (e.g. 'linux_amd64') to its
        `exec_compatible_with` constraints - only the keys are used here.
      versions: list of requested version strings, appended to in place.
      sha256s: dict of "{version}_{platform}" to sha256, filled in place.
      version_url_templates: dict of version to `url_template` override,
        filled in place.
      version_bin_names: dict of version to `bin_name` override, filled in place.
    """
    for tag in mod.tags.version:
        if tag.version not in versions:
            versions.append(tag.version)
        if tag.url_template:
            version_url_templates[tag.version] = tag.url_template
        if tag.bin_name:
            version_bin_names[tag.version] = tag.bin_name

        # An explicit `sha256` on the tag always wins. Otherwise, fall
        # back to the generated mirror in private/versions.bzl (see
        # scripts/mirror_terraform_versions.sh) - but only for the
        # default (HashiCorp) URL: that mirror's checksums are for
        # HashiCorp's own release archives specifically, so they'd be
        # meaningless (and wrong) for a version fetched from a
        # `url_template` override, e.g. an OpenTofu build.
        defaults = {} if tag.url_template else TERRAFORM_VERSIONS.get(tag.version, {})
        for platform in platforms:
            sha256 = tag.sha256.get(platform) or defaults.get(platform, "")
            if sha256:
                sha256s["{}_{}".format(tag.version, platform)] = sha256

def generate_version_toolchain_aliases(lines, versions, platforms, toolchain_type, version_flag, platform_repo_name):
    """Appends the hub repo's per-version-x-platform `config_setting()`/`toolchain()` targets to `lines`.

    Each `toolchain()` points at the real `terraform_toolchain` living in that
    platform's own repository (see `download_version_toolchain`) rather than a
    target in this same repo, so Bazel only fetches the one platform actually
    selected by toolchain resolution for a given target's exec platform,
    instead of every platform up front.

    Args:
      lines: the hub repo's generated BUILD.bazel content, appended to in place.
      versions: list of requested version strings.
      platforms: dict of platform name (e.g. 'linux_amd64') to its
        `exec_compatible_with` constraints.
      toolchain_type: canonical label string of the `toolchain_type` these
        toolchains register against.
      version_flag: canonical label string of the `//:version` build setting
        each `config_setting` matches against.
      platform_repo_name: function `platform -> str` giving the apparent repo
        name of that platform's per-platform repository.
    """
    for version in versions:
        clean_v = version.replace(".", "_")

        lines.append("config_setting(")
        lines.append("    name = \"is_{v}\",".format(v = clean_v))
        lines.append("    flag_values = {\"" + version_flag + "\": \"" + version + "\"},")
        lines.append(")")
        lines.append("")

        for platform, constraints in platforms.items():
            toolchain_name = "terraform_{}_{}".format(clean_v, platform)
            constraints_str = ", ".join(["\"%s\"" % c for c in constraints])

            lines.append("toolchain(")
            lines.append("    name = \"{name}_toolchain\",".format(name = toolchain_name))
            lines.append("    toolchain = \"@{repo}//:terraform_{v}\",".format(repo = platform_repo_name(platform), v = clean_v))
            lines.append("    toolchain_type = \"{toolchain_type}\",".format(toolchain_type = toolchain_type))
            lines.append("    exec_compatible_with = [{constraints}],".format(constraints = constraints_str))
            lines.append("    target_settings = [\":is_{v}\"],".format(v = clean_v))
            lines.append(")")
            lines.append("")

def download_version_toolchain(rctx, lines, platform):
    """Downloads every requested Terraform version's archive for `platform` only.

    Appends the real `terraform_toolchain` BUILD.bazel target to `lines` for
    each. Runs in the per-platform repo that a hub `toolchain()` alias (see
    `generate_version_toolchain_aliases`) points at - so this only executes,
    and only downloads this one platform's archives, once Bazel's toolchain
    resolution actually selects a toolchain living in this repo.

    Args:
      rctx: the per-platform `repository_ctx`, whose `versions`/`sha256s`/
        `version_url_templates`/`version_bin_names` attrs carry every
        requested version's metadata (for every platform - this function
        picks out just `platform`'s).
      lines: the per-platform repo's generated BUILD.bazel content, appended
        to in place.
      platform: the single platform (e.g. 'linux_amd64') this repo is for.
    """
    for version in rctx.attr.versions:
        clean_v = version.replace(".", "_")
        url_template = rctx.attr.version_url_templates.get(version, "")
        bin_name = rctx.attr.version_bin_names.get(version, "")
        sha256 = rctx.attr.sha256s.get("{}_{}".format(version, platform), "")

        rctx.download_and_extract(
            url = _terraform_download_url(url_template, version, platform),
            output = clean_v,
            sha256 = sha256,
        )

        lines.append("terraform_toolchain(")
        lines.append("    name = \"terraform_{v}\",".format(v = clean_v))
        lines.append("    terraform_bin = \"{out_dir}/{bin_name}\",".format(out_dir = clean_v, bin_name = _terraform_bin_name(bin_name, platform)))
        lines.append("    version = \"{version}\",".format(version = version))
        lines.append(")")
        lines.append("")

version_tag = tag_class(
    doc = """Requests a Terraform version be made available for toolchain resolution.

    By default this fetches HashiCorp's own Terraform release
    (`releases.hashicorp.com/terraform/<version>/terraform_<version>_<platform>.zip`,
    binary `terraform`/`terraform.exe`). `url_template`/`bin_name` let you
    point this at a different, compatible CLI release instead - e.g.
    [OpenTofu](https://github.com/opentofu/opentofu), Terraform's open-source
    fork:

        terraform.version(
            version = "1.7.0",
            url_template = "https://github.com/opentofu/opentofu/releases/download/v{version}/tofu_{version}_{platform}.zip",
            bin_name = "tofu",
            sha256 = {...},  # required - the HashiCorp checksum mirror doesn't apply to a url_template override
        )
    """,
    attrs = {
        "version": attr.string(mandatory = True, doc = "Terraform version, e.g. '1.6.0'."),
        "sha256": attr.string_dict(
            doc = "Map of platform (e.g. 'linux_amd64') to the release archive's sha256, for supply-chain integrity. Optional for any 1.x version already in private/versions.bzl (a GPG-verified mirror covering every 1.x release - see scripts/mirror_terraform_versions.sh), as long as `url_template` isn't set (that mirror is HashiCorp-specific) - otherwise required.",
        ),
        "url_template": attr.string(
            doc = "Override the download URL, e.g. for a Terraform-compatible fork like OpenTofu. A string with literal '{version}' and '{platform}' placeholders (platform is e.g. 'linux_amd64') - substituted via Python-style `.format()`. Defaults to HashiCorp's own release URL. Setting this disables the private/versions.bzl checksum-mirror default for `sha256` (see above), since that mirror is specific to HashiCorp's own archives.",
        ),
        "bin_name": attr.string(
            doc = "Override the executable's name inside the downloaded archive, e.g. 'tofu' for OpenTofu. Defaults to 'terraform' ('terraform.exe' on Windows, and '<bin_name>.exe' on Windows if this is set).",
        ),
    },
)
