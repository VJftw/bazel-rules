"""Public API: `terraform_module` (a validated Terraform module), `terraform_root`
(a `terraform_module` that can additionally be `bazel run` to plan/apply/etc
against a pinned Terraform version), and `terraform_local_provider` (an
in-repo-built provider plugin, added to either's offline provider mirror via
their `local_providers` attribute).

The actual rule implementations live under `private/` - this file just wires
up the public names; see `private/common.bzl` for the logic shared by both
rules, `private/module.bzl` for `terraform_module`, `private/root.bzl` for
`terraform_root`, and `private/local_provider.bzl` for
`terraform_local_provider`.
"""

load("//:private/common.bzl", _TerraformModuleInfo = "TerraformModuleInfo")
load("//:private/local_provider.bzl", _TerraformLocalProviderInfo = "TerraformLocalProviderInfo", _terraform_local_provider = "terraform_local_provider")
load("//:private/module.bzl", _terraform_module = "terraform_module")
load("//:private/root.bzl", _terraform_root = "terraform_root")

TerraformModuleInfo = _TerraformModuleInfo
TerraformLocalProviderInfo = _TerraformLocalProviderInfo
terraform_module = _terraform_module
terraform_root = _terraform_root
terraform_local_provider = _terraform_local_provider
