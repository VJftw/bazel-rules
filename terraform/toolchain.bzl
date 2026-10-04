"""Terraform toolchains: a specific Terraform binary, and a mirror of provider plugins."""

TerraformInfo = provider(
    doc = "Information about a specific Terraform binary.",
    fields = {
        "terraform_bin": "File: The terraform executable.",
        "version": "String: The version of Terraform.",
    },
)

def _terraform_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            terraform_info = TerraformInfo(
                terraform_bin = ctx.executable.terraform_bin,
                version = ctx.attr.version,
            ),
        ),
    ]

terraform_toolchain = rule(
    implementation = _terraform_toolchain_impl,
    attrs = {
        "terraform_bin": attr.label(
            executable = True,
            allow_single_file = True,
            cfg = "exec",
            mandatory = True,
        ),
        "version": attr.string(mandatory = True),
    },
)

TerraformProviderMirrorInfo = provider(
    doc = "A Terraform filesystem-mirror directory of provider plugins, for offline `terraform init`.",
    fields = {
        "files": "depset[File]: every provider plugin binary in the mirror.",
    },
)

def _terraform_provider_mirror_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            provider_mirror_info = TerraformProviderMirrorInfo(
                files = depset(ctx.files.providers),
            ),
        ),
    ]

terraform_provider_mirror_toolchain = rule(
    implementation = _terraform_provider_mirror_toolchain_impl,
    attrs = {
        "providers": attr.label_list(
            allow_files = True,
            doc = "Every provider plugin binary file, laid out as a Terraform filesystem mirror (hostname/namespace/type/version/os_arch/binary).",
        ),
    },
)
