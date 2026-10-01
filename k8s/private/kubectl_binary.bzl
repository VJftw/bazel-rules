"""`kubectl_binary`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("//:toolchain.bzl", "KubectlInfo")

_TOOLCHAIN_TYPE = str(Label("//:kubectl_toolchain_type"))

def _kubectl_binary_impl(ctx):
    kubectl_info = ctx.toolchains[_TOOLCHAIN_TYPE].kubectl_info
    kubectl_bin = kubectl_info.kubectl_bin

    # `DefaultInfo.executable` must be one of this target's own declared
    # outputs - it can't just be the toolchain's own File directly - so this
    # symlinks to the resolved binary rather than copying it. Matches
    # kubectl_bin's own extension (".exe" on Windows, none elsewhere), same
    # as the real binary it points at.
    ext = "." + kubectl_bin.extension if kubectl_bin.extension else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(output = executable, target_file = kubectl_bin, is_executable = True)

    return [DefaultInfo(
        executable = executable,
        files = depset([executable]),
        runfiles = ctx.runfiles(files = [kubectl_bin]),
    )]

kubectl_binary = rule(
    implementation = _kubectl_binary_impl,
    executable = True,
    doc = """A directly runnable, hermetic `kubectl` binary - resolved via the
    `kubectl_toolchain_type` toolchain the same way `kustomize_build`/
    `helm_template` resolve their own tools, so `bazel run //path:name --
    <args>` always runs the pinned version (`k8s.kubectl(version = ...)`),
    never whatever (if anything) happens to be on the invoking machine's own
    PATH.

    Unlike `kustomize_build`/`helm_template`, this doesn't render anything
    into a build output - `kubectl` talks to a live cluster over the
    network using whatever kubeconfig the invoking shell's own environment
    points at (`$KUBECONFIG`, `~/.kube/config`, ...), which isn't something
    a hermetic build action can meaningfully do. This rule only makes sure
    the *binary itself* is the pinned, hermetically fetched one.

    The `k8s` module extension also generates a ready-to-use instance of
    this rule at `@k8s//:kubectl` whenever `k8s.kubectl(...)` is declared -
    `bazel run @k8s//:kubectl -- version --client` works with no extra
    `BUILD.bazel` wiring; declare your own `kubectl_binary` target only if
    you want it under a different label/visibility.
    """,
    attrs = {},
    toolchains = [_TOOLCHAIN_TYPE],
)
