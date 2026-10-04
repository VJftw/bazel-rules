# `terraform_root`'s built-in default `script` (see extensions.bzl/root.bzl),
# built as the `//:default_terraform_script` nu_binary.
#
# Every `terraform_root` hands off to *some* script - this is the one used
# when `terraform.default_script` doesn't name another one, so `bazel run
# //path:name -- plan` behaves like running `terraform` directly:
# auto-`init` before any subcommand that needs an initialized working
# directory, then exec the real command.
#
# private/terraform_runner_template.nu has already resolved TF_BIN/
# TF_MODULE_DIR and changed directory into the module dir before handing off
# here - no runfiles lookup, and no `-chdir=...` flag, needed.

const AUTO_INIT_COMMANDS = [plan apply destroy validate refresh import console output]

def --wrapped main [...args] {
    let tf_bin = $env.TF_BIN

    if ($args | is-not-empty) and ($args.0 in $AUTO_INIT_COMMANDS) {
        ^$tf_bin init -input=false -no-color
    }

    if $nu.os-info.name == "windows" {
        ^$tf_bin ...$args
    } else {
        exec $tf_bin ...$args
    }
}
