"""Analysis test for `terraform_local_provider`'s Terraform filesystem-mirror layout."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_terraform//:defs.bzl", "TerraformLocalProviderInfo")

def _local_provider_layout_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[TerraformLocalProviderInfo].files.to_list()
    asserts.equals(env, 1, len(files))

    # The platform segment (e.g. "linux_amd64") depends on whatever exec
    # platform the test itself runs under - only the rest of the mirror
    # layout (hostname/namespace/name/version/.../binary) is asserted here.
    path = files[0].short_path
    asserts.true(env, "/providers/local/myorg/myprovider/0.1.0/" in path, "expected a 'providers/local/myorg/myprovider/0.1.0/' mirror path, got %s" % path)
    asserts.true(
        env,
        files[0].basename == "terraform-provider-myprovider_v0.1.0" or files[0].basename == "terraform-provider-myprovider_v0.1.0.exe",
        "expected provider binary named 'terraform-provider-myprovider_v0.1.0[.exe]', got %s" % files[0].basename,
    )
    return analysistest.end(env)

local_provider_layout_test = analysistest.make(_local_provider_layout_test_impl)
