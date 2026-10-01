# Template for an `opa_test`'s `bazel test` entry point.
#
# Expanded (via `ctx.actions.expand_template`, substituting the `%{...}%`
# tokens below) by opa_test.bzl, and run by the test's nu_launcher (see
# `@rules_nushell//:nu.bzl`). Resolves the opa binary and every test src's
# real runtime path via runfiles (not known until then - build-time paths
# don't survive into a test's own runtime sandbox), then runs `opa test
# <srcs...> <test_args...>`, whose exit code becomes the test's own.

use runfiles.nu

const OPA_BIN_RLOCATION = "%{opa_bin_rlocation}%"

def main [] {
    # Embedded as raw JSON and parsed here, so user-set `test_args` round-trip
    # exactly whatever characters they contain.
    let src_rlocations = (r###'%{src_rlocations_json}%'### | from json)
    let test_args = (r###'%{test_args_json}%'### | from json)

    let opa_bin = (runfiles rlocation $OPA_BIN_RLOCATION)
    let srcs = ($src_rlocations | each {|path| runfiles rlocation $path })
    ^$opa_bin test ...$srcs ...$test_args
}
