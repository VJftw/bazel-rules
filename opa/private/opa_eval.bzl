"""`opa_eval`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("@rules_nushell//:nu.bzl", "NU_TOOLCHAIN_TYPE", "run_nu")
load("//:toolchain.bzl", "OpaInfo")

_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))

def _opa_eval_impl(ctx):
    opa_info = ctx.toolchains[_TOOLCHAIN_TYPE].opa_info
    opa_bin = opa_info.opa_bin

    out = ctx.actions.declare_file(ctx.attr.out or ctx.label.name + ".json")

    # Each src passed as its own `-d` ("set policy or data file(s)") flag,
    # rather than a single `-b`/`--bundle` root dir - unlike `opa build`
    # (see opa_build.bzl), `-d`'s loader follows Bazel's symlinked source
    # inputs without needing a `--follow-symlinks`-equivalent flag (verified
    # empirically), and accepting individual files (not just one shared
    # root directory) means srcs can span multiple packages freely, e.g. a
    # shared policy library referenced by several opa_eval targets.
    opa_args = ["eval", "--format", ctx.attr.format]
    for f in ctx.files.srcs:
        opa_args += ["-d", f.path]
    if ctx.file.input:
        opa_args += ["--input", ctx.file.input.path]
    if ctx.attr.fail_undefined:
        opa_args.append("--fail")
    if ctx.attr.fail_defined:
        opa_args.append("--fail-defined")
    opa_args.append(ctx.attr.query)

    inputs = list(ctx.files.srcs)
    if ctx.file.input:
        inputs.append(ctx.file.input)

    # `opa eval` only ever writes its result to stdout - there's no
    # single-file output flag like `opa build`'s own `-o` - so this runs it
    # through private/capture_stdout.nu (via the hermetic nu resolved from
    # rules_nushell's toolchain, the same way helm_template in rules_k8s
    # does) rather than a `ctx.actions.run_shell` redirection. Keeps the
    # action shell-free on every platform, including Windows.
    run_nu(
        ctx,
        script = ctx.file._capture_stdout_nu,
        outputs = [out],
        inputs = inputs,
        tools = [opa_bin],
        arguments = [opa_bin.path, out.path] + opa_args,
        mnemonic = "OpaEval",
        progress_message = "Evaluating OPA query %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([out]))]

opa_eval = rule(
    implementation = _opa_eval_impl,
    doc = """Evaluates a Rego `query` against `srcs` (and, if set, `input`),
    as a build action - the resolved `opa_toolchain` binary runs `opa eval
    -d <src> [-d <src> ...] [--input <input>] --format <format> <query>`,
    with stdout captured into `out`.

    Setting `fail_undefined`/`fail_defined` turns this into a build-time
    policy gate: with `fail_undefined = True`, building this target fails
    outright if `query` evaluates to undefined/empty against `srcs` (e.g. a
    "this input must satisfy policy X" check) - the same way any other
    failing build action would fail `bazel build`.
    """,
    attrs = {
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "Every .rego policy and data.json/data.yaml file `query` needs, each passed as its own `-d` flag.",
        ),
        "query": attr.string(
            mandatory = True,
            doc = "The Rego query expression to evaluate, e.g. 'data.authz.allow'.",
        ),
        "input": attr.label(
            allow_single_file = [".json", ".yaml", ".yml"],
            doc = "Optional input document, passed via `--input`.",
        ),
        "format": attr.string(
            default = "json",
            values = ["json", "values", "bindings", "pretty", "raw", "discard"],
            doc = "Passed via `--format`. 'source' isn't offered here - it's only meaningful for `-p`/--partial, which this rule doesn't expose.",
        ),
        "fail_undefined": attr.bool(
            default = False,
            doc = "Passed via `--fail` - exits (and so fails this build action) with a non-zero code on an undefined/empty result.",
        ),
        "fail_defined": attr.bool(
            default = False,
            doc = "Passed via `--fail-defined` - exits (and so fails this build action) with a non-zero code on a defined/non-empty result.",
        ),
        "out": attr.string(
            doc = "Output filename. Defaults to the target name + '.json'.",
        ),
        "_capture_stdout_nu": attr.label(default = "//:private/capture_stdout.nu", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN_TYPE, NU_TOOLCHAIN_TYPE],
)
