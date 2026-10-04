"""Analysis tests for `_collect_manifest_entries`'s `dep_sources` requirement."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _missing_dep_sources_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "dep_sources")
    return analysistest.end(env)

missing_dep_sources_test = analysistest.make(
    _missing_dep_sources_test_impl,
    expect_failure = True,
)

def _ok_dep_sources_test_impl(ctx):
    # No custom assertions needed: `analysistest.begin` itself fails the test
    # if the target under test failed analysis, so reaching here at all
    # proves `dep_sources` satisfied `_collect_manifest_entries`.
    env = analysistest.begin(ctx)
    return analysistest.end(env)

ok_dep_sources_test = analysistest.make(_ok_dep_sources_test_impl)
