"""OPA toolchain: a specific `opa` binary."""

OpaInfo = provider(
    doc = "Information about a specific opa binary.",
    fields = {
        "opa_bin": "File: the opa executable.",
        "version": "String: the opa version.",
    },
)

def _opa_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            opa_info = OpaInfo(
                opa_bin = ctx.executable.opa_bin,
                version = ctx.attr.version,
            ),
        ),
    ]

opa_toolchain = rule(
    implementation = _opa_toolchain_impl,
    attrs = {
        "opa_bin": attr.label(
            executable = True,
            allow_single_file = True,
            cfg = "exec",
            mandatory = True,
        ),
        "version": attr.string(mandatory = True),
    },
)
