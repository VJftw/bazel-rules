"""`opa_test`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("@rules_nushell//:nu.bzl", "NU_LAUNCHER_ATTRS", "NU_TOOLCHAIN_TYPE", "nu_launcher", "rlocation_path")
load("//:toolchain.bzl", "OpaInfo")

_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))
_TEST_TEMPLATE = Label("//:private/opa_test_runner_template.nu")

def _opa_test_impl(ctx):
    opa_info = ctx.toolchains[_TOOLCHAIN_TYPE].opa_info
    opa_bin = opa_info.opa_bin

    script = ctx.actions.declare_file(ctx.label.name + "_runner.nu")
    ctx.actions.expand_template(
        template = ctx.file._test_template,
        output = script,
        substitutions = {
            "%{opa_bin_rlocation}%": rlocation_path(ctx, opa_bin),
            "%{src_rlocations_json}%": json.encode([rlocation_path(ctx, f) for f in ctx.files.srcs]),
            "%{test_args_json}%": json.encode(ctx.attr.test_args),
        },
    )

    launcher = nu_launcher(ctx, script)
    runfiles = launcher.runfiles.merge(ctx.runfiles(files = [opa_bin] + ctx.files.srcs))

    return [DefaultInfo(executable = launcher.executable, runfiles = runfiles)]

opa_test = rule(
    implementation = _opa_test_impl,
    test = True,
    doc = """Runs `opa test <srcs...>` against `srcs`' `.rego` policy and
    test files (test cases are rules whose names start with `test_` - see
    https://www.openpolicyagent.org/docs/latest/policy-testing/), as a real
    `bazel test`. Passes iff every test case passes (`opa test` exits 0).

    `bazel test` sandboxes execution with no network access by default
    (unless the test opts in via `tags = ["requires-network"]`), so a
    passing `opa_test` also confirms the whole toolchain resolution +
    runfiles pipeline works without ever reaching the network.
    """,
    attrs = {
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "Every .rego file to test - policies plus their _test.rego files. Each is passed as its own positional path argument to `opa test`, so srcs can span multiple packages freely.",
        ),
        "test_args": attr.string_list(
            default = ["-v"],
            doc = "Extra flags passed to `opa test`, e.g. '--v0-compatible' or '--strict'.",
        ),
        "_test_template": attr.label(default = _TEST_TEMPLATE, allow_single_file = True),
    } | NU_LAUNCHER_ATTRS,
    toolchains = [_TOOLCHAIN_TYPE, NU_TOOLCHAIN_TYPE],
)
