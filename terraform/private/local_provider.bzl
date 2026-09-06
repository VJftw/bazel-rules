"""`terraform_local_provider`: wraps an in-repo-built Terraform provider plugin
binary (e.g. a `go_binary` target implementing the Terraform plugin protocol)
into the same Terraform filesystem-mirror layout `download_provider_mirror`
(private/provider.bzl) produces for a fetched one - so it can be referenced
from a `terraform_module`/`terraform_root`'s `local_providers` attribute
(private/common.bzl) and picked up by `terraform init` from the offline
mirror exactly like a fetched provider, without a network fetch or a
published release.

Not part of the public API - `//:defs.bzl` re-exports it.
"""

TerraformLocalProviderInfo = provider(
    doc = "An in-repo-built Terraform provider plugin, laid out as a (single-provider) Terraform filesystem mirror.",
    fields = {
        "files": "depset[File]: this provider's own binary, laid out at .../providers/<hostname>/<namespace>/<name>/<version>/<platform>/<binary> - the whole subtree shares one root the same way a fetched provider mirror's files do, so `_provider_mirror_root` (private/common.bzl) can find it the same way.",
    },
)

def _terraform_local_provider_impl(ctx):
    namespace, sep, name = ctx.attr.source.rpartition("/")
    if not sep:
        fail("{}: `source` must be \"<namespace>/<name>\", got \"{}\".".format(ctx.label, ctx.attr.source))

    if ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo]):
        os_name = "windows"
    elif ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
        os_name = "darwin"
    elif ctx.target_platform_has_constraint(ctx.attr._linux_constraint[platform_common.ConstraintValueInfo]):
        os_name = "linux"
    else:
        fail("{}: `binary`'s exec platform is none of linux/macos/windows - unsupported.".format(ctx.label))

    if ctx.target_platform_has_constraint(ctx.attr._arm64_constraint[platform_common.ConstraintValueInfo]):
        arch = "arm64"
    elif ctx.target_platform_has_constraint(ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo]):
        arch = "amd64"
    else:
        fail("{}: `binary`'s exec platform is neither x86_64 nor arm64 - unsupported.".format(ctx.label))

    platform = "{}_{}".format(os_name, arch)
    bin_name = "terraform-provider-{}_v{}".format(name, ctx.attr.version)
    if os_name == "windows":
        bin_name += ".exe"

    placed = ctx.actions.declare_file("{name}_mirror/providers/{hostname}/{namespace}/{provider}/{version}/{platform}/{bin_name}".format(
        name = ctx.label.name,
        hostname = ctx.attr.hostname,
        namespace = namespace,
        provider = name,
        version = ctx.attr.version,
        platform = platform,
        bin_name = bin_name,
    ))

    # `binary` is built in the exec configuration (see the `cfg = "exec"`
    # attr below) - same as `terraform_toolchain`'s own `terraform_bin`
    # (toolchain.bzl) - so it's already built for whatever platform actually
    # runs `terraform` (the machine doing the build, or `bazel run`), which
    # is also what `platform` above was computed against. A symlink (not a
    # copy) keeps this cheap regardless of the binary's size.
    ctx.actions.symlink(output = placed, target_file = ctx.executable.binary, is_executable = True)

    return [TerraformLocalProviderInfo(files = depset([placed]))]

terraform_local_provider = rule(
    implementation = _terraform_local_provider_impl,
    doc = """Wraps an in-repo-built Terraform provider plugin binary (e.g. a `go_binary`
    target implementing the Terraform plugin protocol) into the same Terraform
    filesystem-mirror layout a fetched `terraform.provider` produces, so
    `terraform init` picks it up from the offline mirror exactly like a fetched
    one - no network fetch, no published release, no registry required.

    `binary` is built in the exec configuration, so it's automatically built
    for whichever platform ends up actually running `terraform` (the machine
    doing the build, or running `bazel run`) rather than the build's target
    platform - the same way `terraform_toolchain`'s own `terraform_bin` is.

    Reference this from a `terraform_module`/`terraform_root`'s
    `local_providers` attribute:

    ```starlark
    go_binary(
        name = "myprovider_bin",
        embed = [":myprovider_lib"],
    )

    terraform_local_provider(
        name = "myprovider",
        binary = ":myprovider_bin",
        source = "myorg/myprovider",
        version = "0.1.0",
        hostname = "local",  # avoid colliding with a real registry.terraform.io namespace
    )

    terraform_root(
        name = "root",
        srcs = ["main.tf"],
        local_providers = [":myprovider"],
        version = "1.6.0",
    )
    ```

    with a matching `required_providers` block:

    ```hcl
    terraform {
      required_providers {
        myprovider = {
          source  = "local/myorg/myprovider"
          version = "0.1.0"
        }
      }
    }
    ```
    """,
    attrs = {
        "binary": attr.label(
            executable = True,
            cfg = "exec",
            mandatory = True,
            doc = "The provider plugin's own executable (e.g. a `go_binary` target implementing the Terraform plugin protocol).",
        ),
        "source": attr.string(
            mandatory = True,
            doc = "Provider source address's \"<namespace>/<name>\" part, e.g. 'myorg/myprovider' - combined with `hostname` for the full address. Must match the consuming `.tf`'s `required_providers` `source` exactly.",
        ),
        "version": attr.string(mandatory = True, doc = "Provider version, e.g. '0.1.0' - must match the consuming `.tf`'s `required_providers` block exactly."),
        "hostname": attr.string(
            default = "registry.terraform.io",
            doc = "Provider source hostname. Defaults to 'registry.terraform.io' (matching `terraform.provider`'s convention) but a local/in-repo provider is usually better given a distinct hostname (e.g. 'local') so it can't collide with, or be confused for, a real registry.terraform.io namespace.",
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
        "_macos_constraint": attr.label(default = "@platforms//os:macos"),
        "_linux_constraint": attr.label(default = "@platforms//os:linux"),
        "_x86_64_constraint": attr.label(default = "@platforms//cpu:x86_64"),
        "_arm64_constraint": attr.label(default = "@platforms//cpu:arm64"),
    },
)
