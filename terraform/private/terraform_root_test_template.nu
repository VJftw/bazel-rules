# Template for a `terraform_root_test`'s `bazel test` entry point.
#
# Expanded (via `ctx.actions.expand_template`, substituting the `%{...}%`
# tokens below) by `testing.bzl`, and run by the test's nu_launcher (see
# `@rules_nushell//:nu.bzl`) - just locates the `terraform_root`'s own
# executable via runfiles and runs it with `tf_args`, whose exit code becomes
# the test's own.

use runfiles.nu

const RUNNER_RLOCATION = "%{runner_rlocation}%"

def main [] {
    let runner = (runfiles rlocation $RUNNER_RLOCATION)
    let tf_args = (r###'%{tf_args_json}%'### | from json)
    # Run (not `exec`) - on Windows, `runner` may be a `.bat` launcher.
    ^$runner ...$tf_args
}
