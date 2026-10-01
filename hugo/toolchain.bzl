"""Hugo toolchain: a specific `hugo` binary."""

HugoInfo = provider(
    doc = "Information about a specific hugo binary.",
    fields = {
        "hugo_bin": "File: the hugo executable.",
        "version": "String: the hugo version.",
        "variant": "String: the release variant ('hugo', 'extended', 'extended_withdeploy', or 'withdeploy').",
    },
)

def _hugo_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            hugo_info = HugoInfo(
                hugo_bin = ctx.executable.hugo_bin,
                version = ctx.attr.version,
                variant = ctx.attr.variant,
            ),
        ),
    ]

hugo_toolchain = rule(
    implementation = _hugo_toolchain_impl,
    attrs = {
        "hugo_bin": attr.label(
            executable = True,
            allow_single_file = True,
            cfg = "exec",
            mandatory = True,
        ),
        "version": attr.string(mandatory = True),
        "variant": attr.string(mandatory = True),
    },
)
