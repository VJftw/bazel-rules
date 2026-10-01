# Runs a program, capturing its stdout into a file.
#
# `helm template` only ever writes its rendered manifest to stdout - there's
# no single-file output flag like kustomize's own `--output` - so
# helm_template's build action runs it through this script instead of a
# `ctx.actions.run_shell` shell redirection, via the hermetic nu resolved
# from rules_nushell's toolchain. Keeps the action shell-free on every
# platform, including Windows. A non-zero exit code from the program becomes
# this script's own, failing the action.

def --wrapped main [bin: string, out: string, ...args] {
    ^$bin ...$args o> $out
}
