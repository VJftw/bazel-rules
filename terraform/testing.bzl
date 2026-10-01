"""A `bazel test` that runs a `terraform_root` for real, inside the sandbox.

`bazel test` sandboxes execution with no network access by default (unless a
test opts in via `tags = ["requires-network"]`), so a passing
`terraform_root_test` is also a hermeticity regression test: if the
toolchain, provider mirror, or any `registry_modules` manifest fabrication
ever needed the network, `terraform plan` would fail to reach it and the
test would fail.
"""

load("@rules_nushell//:nu.bzl", "NU_LAUNCHER_ATTRS", "NU_TOOLCHAIN_TYPE", "nu_launcher", "rlocation_path")

_TEST_TEMPLATE = Label("//:private/terraform_root_test_template.nu")

def _terraform_root_test_impl(ctx):
    root_info = ctx.attr.root[DefaultInfo]
    runner = root_info.files_to_run.executable

    script = ctx.actions.declare_file(ctx.label.name + "_runner.nu")
    ctx.actions.expand_template(
        template = ctx.file._test_template,
        output = script,
        substitutions = {
            "%{runner_rlocation}%": rlocation_path(ctx, runner),
            "%{tf_args_json}%": json.encode(ctx.attr.tf_args),
        },
    )

    launcher = nu_launcher(ctx, script)
    executable = launcher.executable

    runfiles = ctx.runfiles(files = [runner])
    runfiles = runfiles.merge_all([
        launcher.runfiles,
        root_info.default_runfiles,
    ])

    return [DefaultInfo(executable = executable, runfiles = runfiles)]

terraform_root_test = rule(
    implementation = _terraform_root_test_impl,
    test = True,
    doc = """Runs `terraform plan` (or whatever `tf_args` says) against an
    already-built `terraform_root`, as a `bazel test`. Passes iff that command
    exits 0.
    """,
    attrs = {
        "root": attr.label(mandatory = True, executable = True, cfg = "target"),
        "tf_args": attr.string_list(default = ["plan", "-input=false", "-no-color"]),
        "_test_template": attr.label(default = _TEST_TEMPLATE, allow_single_file = True),
    } | NU_LAUNCHER_ATTRS,
    toolchains = [NU_TOOLCHAIN_TYPE],
)
