"""`plantuml_diagram`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//:toolchain.bzl", "PlantUMLInfo")

_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))

# Bazel's own built-in toolchain type for a plain JVM (no compiler needed,
# just enough to `java -jar` the already-built PlantUML jar) - resolved via
# normal toolchain resolution the same as any other toolchain, so this module
# doesn't need its own `bazel_dep` on `rules_java` (or similar) just to run a
# jar.
_JAVA_RUNTIME_TOOLCHAIN_TYPE = "@bazel_tools//tools/jdk:runtime_toolchain_type"

# PlantUML's `-t<fmt>` flag names match the output file extension it writes
# for each of these formats, so no separate flag<->extension table is needed.
_FORMATS = ["svg", "png", "eps", "pdf"]

def _java_version_transition_impl(_settings, _attr):
    # Bazel's `--java_runtime_version` defaults to "local_jdk" - whatever `java`
    # happens to be on the machine running Bazel, or a hard failure if there
    # isn't one. Pinning it here, unconditionally, means a `plantuml_diagram`
    # always renders with the same hermetic, Bazel-fetched JVM regardless of
    # the invoking machine's own Java installation (or lack of one) - the same
    # hermeticity rules_terraform's own `nu` resolution gets from
    # rules_nushell, just via Bazel's built-in Java toolchain instead.
    return {"//command_line_option:java_runtime_version": "remotejdk_21"}

_JAVA_VERSION_TRANSITION = transition(
    implementation = _java_version_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:java_runtime_version"],
)

def _relative_output_dir(src_dir, out_dir):
    # PlantUML resolves a relative `-o` against the INPUT file's own
    # directory, not the process's cwd (verified empirically - it logs
    # "Setting current dir: <dirname of src>" before resolving `-o` against
    # that) - so passing `out_dir` (an execroot-relative path, as declared
    # outputs always are) straight through would only land correctly when
    # `src` happens to live at the execroot's own root. Instead, resolve it
    # relative to `src`'s own directory, the same way a shell's `cd
    # $src_dir && $tool -o $result` would.
    if src_dir in ("", "."):
        return out_dir
    return "/".join([".."] * len(src_dir.split("/")) + [out_dir])

def _plantuml_diagram_impl(ctx):
    plantuml_info = ctx.toolchains[_TOOLCHAIN_TYPE].plantuml_info
    java_runtime = ctx.toolchains[_JAVA_RUNTIME_TOOLCHAIN_TYPE].java_runtime

    fmt = ctx.attr.format
    out = ctx.actions.declare_file(paths.replace_extension(ctx.file.src.basename, "." + fmt))

    args = ctx.actions.args()

    # PNG rendering reflectively touches a JDK-internal ImageIO class; JDK 17+'s
    # module system blocks that access by default (JEP 403), so PlantUML's own
    # PNG writer throws IllegalAccessError without this - see
    # https://github.com/plantuml/plantuml/issues/1830.
    args.add("--add-opens=java.desktop/com.sun.imageio.plugins.png=ALL-UNNAMED")
    args.add("-jar", plantuml_info.jar)
    args.add("-t" + fmt)
    args.add("-charset", "UTF-8")

    # Deterministic (single-threaded) rendering, and no version-check phone
    # home to plantuml.com - keeps the action hermetic.
    args.add("-nbthread", "1")
    args.add("-quiet")
    args.add("-o", _relative_output_dir(ctx.file.src.dirname, out.dirname))
    args.add(ctx.file.src)

    ctx.actions.run(
        outputs = [out],
        inputs = depset(
            [ctx.file.src, plantuml_info.jar] + ctx.files.deps,
            transitive = [java_runtime.files],
        ),
        executable = java_runtime.java_executable_exec_path,
        arguments = [args],
        mnemonic = "PlantUML",
        progress_message = "Rendering PlantUML diagram %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([out]))]

plantuml_diagram = rule(
    implementation = _plantuml_diagram_impl,
    cfg = _JAVA_VERSION_TRANSITION,
    doc = """Renders a single PlantUML `.puml` source into a diagram image, as a build
    action - the resolved `plantuml_toolchain` jar is run via a Bazel-fetched
    JVM (see `_JAVA_VERSION_TRANSITION` above), never a `java` assumed to be
    on PATH.

    Assumes `src` contains exactly one `@startuml`/`@enduml` diagram - PlantUML
    itself supports several diagrams per file, but then names its outputs
    after each diagram's own title (unpredictable at analysis time, when
    Bazel needs to already know the declared output's exact name), so this
    rule only declares (and only requires that PlantUML produce) the one file
    matching `src`'s own basename.
    """,
    attrs = {
        "src": attr.label(
            mandatory = True,
            allow_single_file = [".puml", ".plantuml", ".pu"],
            doc = "The PlantUML source file to render.",
        ),
        "deps": attr.label_list(
            allow_files = True,
            doc = "Other files `src` references via `!include`, e.g. other `.puml` files, a `filegroup`, or a `plantuml_library` it pulls shared styling/macros from.",
        ),
        "format": attr.string(
            default = "svg",
            values = _FORMATS,
            doc = "Output format to render.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE, _JAVA_RUNTIME_TOOLCHAIN_TYPE],
)
