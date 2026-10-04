"""A specific PlantUML jar, wired up through Bazel's toolchain mechanism."""

PlantUMLInfo = provider(
    doc = "Information about a specific PlantUML jar.",
    fields = {
        "jar": "File: the PlantUML jar (net.sourceforge.plantuml:plantuml).",
        "version": "String: the PlantUML version.",
    },
)

def _plantuml_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            plantuml_info = PlantUMLInfo(
                jar = ctx.file.jar,
                version = ctx.attr.version,
            ),
        ),
    ]

plantuml_toolchain = rule(
    implementation = _plantuml_toolchain_impl,
    attrs = {
        "jar": attr.label(
            allow_single_file = [".jar"],
            mandatory = True,
            doc = "The PlantUML jar.",
        ),
        "version": attr.string(mandatory = True),
    },
)
