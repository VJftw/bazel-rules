"""A pre-fetched, hermetic third-party (registry or git) Terraform module."""

TerraformRegistryModuleInfo = provider(
    doc = "A third-party Terraform module fetched hermetically, staged into a consuming module's `.terraform/modules/` manifest instead of being resolved over the network at `init` time.",
    fields = {
        "files": "depset[File]: every file in the module.",
        "root": "String: the repo-relative directory prefix under which `files` live (stripped when staging the module under a consumer's `_registry_modules/<key>/`).",
        "source": "String: the module source address exactly as Terraform's own module manifest records it (e.g. 'registry.terraform.io/cloudposse/label/null').",
        "version": "String: the resolved module version, for registry sources; empty for unversioned (e.g. git ref) sources.",
        "nested": "dict[string, TerraformRegistryModuleInfo]: other third-party modules this module's own (fetched, vendored) .tf files reference internally, keyed by the local module call name used inside this module. The extension can't discover these on its own (it never parses .tf content) - declared explicitly via the `terraform.module` tag's `nested` attr.",
    },
)

def _terraform_registry_module_impl(ctx):
    nested = {key: target[TerraformRegistryModuleInfo] for key, target in ctx.attr.nested.items()}
    return [
        TerraformRegistryModuleInfo(
            files = depset(ctx.files.srcs),
            root = ctx.attr.root,
            source = ctx.attr.source,
            version = ctx.attr.version,
            nested = nested,
        ),
    ]

terraform_registry_module = rule(
    implementation = _terraform_registry_module_impl,
    doc = "Wraps a hermetically fetched third-party Terraform module (see the `terraform` module extension's `.module()` tag) for use in `terraform_module`/`terraform_root`'s `registry_modules` attribute.",
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "root": attr.string(mandatory = True),
        "source": attr.string(mandatory = True),
        "version": attr.string(default = ""),
        "nested": attr.string_keyed_label_dict(
            providers = [TerraformRegistryModuleInfo],
            doc = "Other `terraform_registry_module` targets this module's own vendored .tf files reference internally, keyed by the local module call name used inside this module.",
        ),
    },
)
