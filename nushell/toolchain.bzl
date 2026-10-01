"""Nushell toolchain: a specific `nu` binary."""

NushellInfo = provider(
    doc = "Information about a specific nu binary.",
    fields = {
        "nu_bin": "File: the nu executable.",
        "version": "String: the Nushell version.",
    },
)

def _nu_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            nushell_info = NushellInfo(
                nu_bin = ctx.executable.nu_bin,
                version = ctx.attr.version,
            ),
        ),
    ]

nu_toolchain = rule(
    implementation = _nu_toolchain_impl,
    attrs = {
        "nu_bin": attr.label(
            executable = True,
            allow_single_file = True,
            cfg = "exec",
            mandatory = True,
        ),
        "version": attr.string(mandatory = True),
    },
)
