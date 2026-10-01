# Runs `terraform init && terraform validate` against a staged module tree.
#
# Invoked as a build action (via the hermetic nu from rules_nushell's
# toolchain, not a shell) - see `validate_action` in private/common.bzl. All
# paths are plain, already execroot-relative paths; no runfiles resolution is
# needed here (unlike private/terraform_runner_template.nu, which runs later,
# outside the build sandbox).
#
# TF_DATA_DIR is a plain scratch directory (not a declared Bazel output) -
# Terraform's filesystem-mirror provider install symlinks straight into it
# from the mirror's own input files, and a declared tree-artifact output
# can't contain symlinks pointing outside itself (Bazel rejects them as
# "dangling" once the action's sandbox is torn down). Only the `.validated`
# marker file is an actual tracked output; this directory's lifetime is the
# same as any other action-local scratch space.

# One `filesystem_mirror` block per independent mirror root (the
# toolchain-fetched mirror, plus one per `terraform_local_provider` - see
# `collect_provider_mirror_sources` in private/common.bzl), each `include`d
# unconditionally since every root only ever holds the providers it was
# actually given. `direct` is excluded unconditionally too (rather than just
# excluding a specific hostname) - a provider that isn't in any mirror should
# fail loudly (no filesystem mirror package found), not silently reach out to
# the network (which the build/test sandbox blocks anyway).
def provider-cli-config [mirror_roots: list<string>]: nothing -> string {
    let blocks = ($mirror_roots | each {|root|
        $"\n  filesystem_mirror {\n    path    = \"($root)\"\n    include = [\"*/*/*\"]\n  }"
    } | str join "\n")
    $"\ndisable_checkpoint = true\n\nprovider_installation {\n($blocks)\n  direct {\n    exclude = [\"*/*/*\"]\n  }\n}\n"
}

def is-absolute []: string -> bool {
    ($in | str starts-with "/") or ($in =~ '^[A-Za-z]:[\\/]')
}

def main [
    --terraform-bin: string
    --module-dir: string
    --marker: string  # Output file to create on success.
    --manifest-seed: string = ""  # Pre-built modules.json to seed into TF_DATA_DIR/modules/, if any.
    ...provider_mirror_roots: string  # Execroot-relative paths to provider filesystem mirror roots, one per independent mirror source.
] {
    # `-chdir` changes the process's cwd before Terraform resolves TF_DATA_DIR
    # or anything inside the pre-fab manifest, so a *relative* TF_DATA_DIR (or
    # a relative "Dir" entry within modules.json) would then be resolved
    # relative to the wrong (post-chdir) directory. Absolute-ify everything
    # up front instead.
    let cwd = $env.PWD
    let terraform_bin = ($terraform_bin | path expand --no-symlink)
    let module_dir = ($module_dir | path expand --no-symlink)
    let data_dir = (mktemp --directory)

    mut env_vars = {TF_DATA_DIR: $data_dir}
    if ($provider_mirror_roots | is-not-empty) {
        let cli_config_path = ($data_dir | path join .terraformrc)
        provider-cli-config ($provider_mirror_roots | each {|root| $root | path expand --no-symlink })
        | save --force $cli_config_path
        $env_vars = ($env_vars | insert TF_CLI_CONFIG_FILE $cli_config_path)
    }

    if $manifest_seed != "" {
        let manifest = (open $manifest_seed)
        let modules = ($manifest.Modules | each {|entry|
            let dir = ($entry.Dir? | default "")
            if $dir != "" and not ($dir | is-absolute) {
                $entry | update Dir ($cwd | path join $dir)
            } else {
                $entry
            }
        })
        let modules_dir = ($data_dir | path join modules)
        mkdir $modules_dir
        $manifest | update Modules $modules | to json --raw | save --force ($modules_dir | path join modules.json)
    }

    let chdir = $"-chdir=($module_dir)"
    with-env $env_vars {
        ^$terraform_bin $chdir init -input=false -backend=false -no-color
        ^$terraform_bin $chdir validate -no-color
    }

    touch $marker
}
