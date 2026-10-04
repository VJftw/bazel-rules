# rules_k8s

A small Bazel module providing hermetic `kustomize_build` (renders a
[Kustomize](https://kustomize.io/) overlay into a single merged manifest),
`helm_template` (renders a [Helm](https://helm.sh/) chart into a single
merged manifest), `k8s_manifests` (aggregates manifest files and/or other
rendered targets into one target), and `kubectl_binary` (a directly
runnable, hermetic [kubectl](https://kubernetes.io/docs/reference/kubectl/))
rules.

## Quickstart

In your `.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/VJftw/bazel-rules/main/registry/
common --registry=https://bcr.bazel.build
```

In your root `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_k8s", version = "0.1.0")

k8s = use_extension("@rules_k8s//:extensions.bzl", "k8s")
k8s.kustomize(version = "5.8.1")  # see Checksum mirror below for why no sha256
k8s.helm(version = "3.22.0")
k8s.kubectl(version = "1.37.1")
use_repo(k8s, "k8s")

register_toolchains("@k8s//:all")
```

In a `BUILD.bazel` next to a kustomization:

```starlark
load("@rules_k8s//:defs.bzl", "kustomize_build")

kustomize_build(
    name = "hello_prod",
    kustomization = "kustomization.yaml",
)
```

```console
$ bazel build //:hello_prod
$ bazel run @k8s//:kubectl -- version --client   # kubectl works immediately too, no BUILD.bazel needed
```

See [Usage](#usage) below for `helm_template`, the full BCR/`git_override`/
local dev options, and each rule's own dedicated section for more (helm+
kustomize composition, bundling, etc).

## Contents

- [Rules](#rules)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Composing helm and kustomize](#composing-helm-and-kustomize)
- [Bundling manifests](#bundling-manifests)
- [Running kubectl](#running-kubectl)
- [Symlinks and `--load-restrictor`](#symlinks-and---load-restrictor)
- [Supported platforms](#supported-platforms)
- [Checksum mirror](#checksum-mirror)
- [Windows](#windows)
- [Layout](#layout)

## Rules

- **`kustomize_build`**: renders a kustomization directory (`kustomization`
  plus every file it needs, listed in `srcs`) into a single merged manifest
  via `kustomize build <dir> --output <out>`. Defaults
  `--load-restrictor=LoadRestrictionsNone` (see Symlinks and
  `--load-restrictor` below) - override via the `load_restrictor` attr if you
  specifically want kustomize's own `RootOnly` behavior for some other
  reason. `resources` (a dict, empty by default) makes another target's
  output - typically a `helm_template` - resolvable at a literal path inside
  `kustomization`'s own directory, so this kustomization's own `resources:`
  list (and its own transformers - `namespace`, `labels`, patches, ...) can
  reference and apply to it - see Composing helm and kustomize below.
- **`helm_template`**: renders a Helm chart (`chart_yaml` plus every file it
  needs, listed in `srcs`) into a single merged manifest via `helm template
  <release_name> <dir> ...`, with `values`/`set_values`/`namespace`/
  `include_crds` attrs mapping to the equivalent `helm template` flags.
  Captures `helm template`'s stdout into `out` via `private/capture_stdout.nu`
  (unlike `kustomize build`, `helm template` has no single-file output flag) -
  see How it works below.
- **`k8s_manifests`**: aggregates plain manifest files (`srcs`) and/or other
  `K8sManifestInfo`-providing targets (`deps`) into one target - see
  Bundling manifests below.
- **`kubectl_binary`**: a directly runnable, hermetic `kubectl` - `bazel run
  //path:name -- <args>` runs the pinned version against whatever
  kubeconfig/cluster the invoking shell's own environment points at. See
  Running kubectl below - in most cases you don't even need to declare this
  yourself, since `k8s.kubectl(...)` already generates a ready-to-use
  `@k8s//:kubectl`.

## Usage

This module doesn't need a [Bazel Central Registry](https://registry.bazel.build/)
release to be consumable as a plain `bazel_dep` - the
[bazel-rules](https://github.com/VJftw/bazel-rules) repo this lives in
self-hosts a real module registry at `registry/`, updated on every release
(see its own README's "Consuming a module from here directly"). Add to your
`.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/VJftw/bazel-rules/main/registry/
common --registry=https://bcr.bazel.build
```

Then, in your root `MODULE.bazel` (works the same whether resolved from that
registry or, later, from BCR directly):

```starlark
bazel_dep(name = "rules_k8s", version = "0.1.0")

k8s = use_extension("@rules_k8s//:extensions.bzl", "k8s")
k8s.kustomize(
    version = "5.8.1",  # see https://github.com/kubernetes-sigs/kustomize/releases
    sha256 = {...},  # optional, but recommended
)
k8s.helm(
    version = "3.22.0",  # see https://github.com/helm/helm/releases
    sha256 = {...},  # optional, but recommended
)
k8s.kubectl(
    version = "1.37.1",  # see https://dl.k8s.io/release/stable.txt for the latest
    sha256 = {...},  # optional, but recommended
)
use_repo(k8s, "k8s")

register_toolchains("@k8s//:all")
```

Before this module has a BCR release, or to develop against an unreleased
change, use a `git_override` (pinned to a commit) or, for a local checkout of
this repo, a `local_path_override` instead of the `bazel_dep` version above -
both need the same `strip_prefix`/`path` pointing at this module's own
`k8s/` subdirectory, since this repo is a monorepo of multiple modules:

```starlark
bazel_dep(name = "rules_k8s", version = "0.1.0")

# Option A: pin to a commit on the bazel-rules repo.
git_override(
    module_name = "rules_k8s",
    remote = "https://github.com/VJftw/bazel-rules.git",
    commit = "<commit-sha>",
    strip_prefix = "k8s",
)

# Option B: a local checkout of VJftw/bazel-rules, e.g. for developing
# rules_k8s itself alongside a consumer.
local_path_override(
    module_name = "rules_k8s",
    path = "../bazel-rules/k8s",
)
```

In a `BUILD.bazel` next to a kustomization:

```starlark
load("@rules_k8s//:defs.bzl", "kustomize_build")

kustomize_build(
    name = "hello_prod",
    kustomization = "kustomization.yaml",
    srcs = ["//path/to/base:srcs"],  # every file the overlay's bases/patches/etc need
)
```

`bazel build //path:hello_prod` renders it into `hello_prod.yaml` using the
pinned kustomize version.

In a `BUILD.bazel` next to a Helm chart:

```starlark
load("@rules_k8s//:defs.bzl", "helm_template")

helm_template(
    name = "hello",
    chart_yaml = "Chart.yaml",
    srcs = glob(["templates/**"]) + ["values.yaml"],
    release_name = "hello-prod",
    namespace = "hello-prod",
    set_values = ["image.tag=1.2.3"],
)
```

`bazel build //path:hello` renders it into `hello.yaml` using the pinned
helm version.

## How it works

- **Toolchains**: the `kustomize`, `helm`, and `kubectl` binaries are all
  wired up through Bazel's
  [toolchain](https://bazel.build/extending/toolchains) mechanism
  (`kustomize_toolchain_type`/`helm_toolchain_type`/`kubectl_toolchain_type`,
  `kustomize_toolchain`/`helm_toolchain`/`kubectl_toolchain`, `toolchain()`),
  not hardcoded labels - resolution follows normal Bazel toolchain rules
  (exec platform matching, registration order, etc), the same as
  `rules_terraform`'s own Terraform toolchain.
- **Single repository, from `MODULE.bazel`'s perspective**: every requested
  version is addressable through one external repository, `@k8s` (see
  `extensions.bzl`) - there's no per-tool, per-platform repo to wire up
  yourself, just one `use_repo(k8s, "k8s")` and one
  `register_toolchains("@k8s//:all")`. Under the hood `@k8s` is a thin hub of
  `toolchain()` aliases; the actual archives are fetched lazily, one real
  repository per platform, only for whichever platform a given build's
  toolchain resolution actually selects - see Supported platforms below.
- **Independent tools**: `k8s.kustomize(...)`/`k8s.helm(...)`/
  `k8s.kubectl(...)` are each optional and independent - a build using only
  `kustomize_build` need not declare `k8s.helm(...)`/`k8s.kubectl(...)` at
  all, and so on for any combination. Unlike `rules_terraform`, only one
  version of each tool can be active in a given build - none of the three
  rules pins a version per target, so the extra config-setting/transition
  machinery Terraform needs (for genuinely simultaneous versions in one
  build) isn't justified here.
- **No staging into a synthetic tree**: both rules run their action directly
  against `srcs`' real source-tree-relative paths (unlike
  `rules_terraform`'s `stage_module`, which copies files into a tree
  artifact mainly so Terraform has somewhere writable to put `.terraform/`) -
  a `bases: [../other]` (kustomize) or vendored `charts/` subchart (helm)
  reference resolves correctly as long as that other directory's files are
  also listed in `srcs` (e.g. via a `filegroup` in that directory's own
  `BUILD.bazel`).
- **No bash dependency**: `helm_template`'s build action (the one rule here
  that can't just ask its own CLI to write a single output file - `helm
  template` only ever writes its rendered manifest to stdout) captures that
  stdout via `private/capture_stdout.nu`, run through a hermetic `nu`
  resolved from [`rules_nushell`](../nushell/README.md)'s toolchain
  (`bazel_dep(name = "rules_nushell")` in this module's own `MODULE.bazel` -
  it registers its own toolchains and default version, propagating to
  consumers automatically, no extra `MODULE.bazel` wiring needed on your
  side), rather than a `ctx.actions.run_shell` redirection - the same
  approach `rules_terraform` uses for its own build actions. Works
  identically on every platform, including Windows - no Git-Bash/MSYS2
  dependency. `kustomize_build`'s own (opt-in, only when `resources` is set)
  staging path reuses the same `nu` for the same reason - see Composing
  helm and kustomize below.
- **Composable by design**: `helm_template` and `kustomize_build` both
  return a common `K8sManifestInfo` provider (see `manifest.bzl`) alongside
  the usual `DefaultInfo` - a `helm_template` output can be fed straight
  into a `kustomize_build`'s `resources` (see Composing helm and kustomize
  below), a `kustomize_build` output can feed a further `kustomize_build`
  the same way, and `k8s_manifests` aggregates any number of these (or
  plain files) into one target, the same way `plantuml_library` aggregates
  PlantUML include files in `rules_plantuml`.

## Composing helm and kustomize

To post-process a Helm chart's output through kustomize (apply a
`namespace`, `labels`, a strategic-merge patch, etc, on top of what `helm
template` produced), point `kustomize_build`'s `resources` at the
`helm_template` target, keyed by whatever relative path your own
`kustomization.yaml` already references:

```starlark
load("@rules_k8s//:defs.bzl", "helm_template", "kustomize_build")

helm_template(
    name = "hello_chart",
    chart_yaml = "chart/Chart.yaml",
    srcs = glob(["chart/templates/**"]) + ["chart/values.yaml"],
)

kustomize_build(
    name = "hello_prod",
    kustomization = "kustomization.yaml",
    resources = {"rendered.yaml": ":hello_chart"},
)
```

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: hello-prod
resources:
  - rendered.yaml
```

`bazel build //path:hello_prod` now produces the Helm chart's Deployment
with `namespace: hello-prod` actually applied to it.

This only works, and only means anything, because `rendered.yaml` ends up as
a first-class `resources:` entry of `kustomization.yaml` itself - kustomize's
own transformers only apply to resources declared within the *same*
kustomization (verified empirically: merely stacking the rendered file in
as a sibling of an unrelated *other* kustomization does not apply that other
kustomization's transformers to it). Since the real, checked-in
`kustomization.yaml` can't be edited by a build action, and a generated
file can't be dropped directly into the real (read-only, symlinked) source
directory either, setting `resources` switches `kustomize_build` to a
staged build: it copies `kustomization` + `srcs` into a writable tree
(preserving their real relative layout, so a `bases: [../other]` reference
keeps resolving exactly as it does unstaged), places each `resources` entry
at `<key>` relative to `kustomization`'s own directory within that tree, and
runs `kustomize build` against the staged copy instead of the real source
directory. Leaving `resources` unset (the default) skips staging
entirely - it's an opt-in cost, not something every `kustomize_build` pays.

`resources`' values aren't limited to `helm_template` - a plain file, a
`filegroup`, or another `kustomize_build` (composing kustomize-of-kustomize
the same way) all work; each must resolve to exactly one file (via
`K8sManifestInfo.manifests` if the target provides it, else
`DefaultInfo.files`) - a target with several outputs is a build error here,
since there'd be no single file for a single dict key to mean. See
`examples/chart_kustomize/`.

## Bundling manifests

`k8s_manifests` aggregates several rendered manifests - or plain checked-in
ones - into one target, without merging their content into a single file:

```starlark
load("@rules_k8s//:defs.bzl", "k8s_manifests")

k8s_manifests(
    name = "manifests",
    deps = [
        "//chart:hello",
        "//chart_kustomize:hello_prod",
        "//overlay:hello_prod",
    ],
)
```

`bazel build //path:manifests` builds all three, and `DefaultInfo.files`
carries every individual output - useful as one target to depend on for
"everything this environment needs" (e.g. handed to a `kubectl apply -f
bazel-bin/path/` equivalent, or as `srcs`/`resources` for something further
downstream), without flattening the whole dependency chain into every
consumer's own `deps` by hand. `deps` composes transitively, the same way
`plantuml_library`'s own `deps` does in `rules_plantuml` - a `k8s_manifests`
target can itself be a `deps` entry of another one.

## Running kubectl

Declaring `k8s.kubectl(version = "1.37.1", ...)` in `MODULE.bazel` is
enough on its own - it generates a ready-to-use `@k8s//:kubectl` target, so:

```console
$ bazel run @k8s//:kubectl -- version --client
Client Version: v1.37.1
Kustomize Version: v5.8.1
```

works immediately, no `BUILD.bazel` wiring needed. Declare your own
`kubectl_binary` target only if you want it under a different label or
visibility:

```starlark
load("@rules_k8s//:defs.bzl", "kubectl_binary")

kubectl_binary(
    name = "kubectl",
    visibility = ["//visibility:public"],
)
```

`kubectl_binary` is deliberately just the binary, resolved hermetically -
unlike `kustomize_build`/`helm_template`, it doesn't manage cluster state or
kubeconfig itself. `kubectl` talks to a live cluster over the network using
whatever the invoking shell's own environment already points at
(`$KUBECONFIG`, `~/.kube/config`, ...), which isn't something a hermetic
*build* action can meaningfully do (there's no "the build produced the
right cluster state" the way there's "the build produced the right YAML
file") - so this rule only guarantees the binary itself is the pinned,
hermetically fetched one, never whatever (if anything) happens to be on the
invoking machine's own PATH. It composes naturally with the rest of this
module regardless - e.g. `bazel run @k8s//:kubectl -- apply -f
bazel-bin/path/to/hello_prod.yaml` against a `kustomize_build`/
`helm_template` output, or `-k` against a plain kustomization directory
(kubectl bundles its own vendored kustomize for that - visible in the
`version --client` output above - independent of this module's own pinned
`k8s.kustomize(...)` version).

## Symlinks and `--load-restrictor`

Bazel always materializes source-file inputs to a sandboxed build action as
symlinks pointing back at the real source tree (not copies) - this is
fundamental to how Bazel exposes sources, not specific to this module's
rules. kustomize's default load restrictor (`LoadRestrictionsRootOnly`)
refuses to even find a kustomization file that's a symlink, regardless of
where it points (verified empirically - a real symlinked `kustomization.yaml`
whose target is well within the intended root still fails with "unable to
find one of 'kustomization.yaml', ..." under the default restrictor, and
succeeds identically once `--load-restrictor=LoadRestrictionsNone` is
passed). Since Bazel's own action sandboxing (explicit `srcs`, no other
inputs visible to the action) already provides the isolation kustomize's
flag exists for, `kustomize_build` defaults to `LoadRestrictionsNone` rather
than inheriting kustomize's own stricter default - see `load_restrictor` on
`kustomize_build` to override it.

## Supported platforms

`linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64`, `windows_amd64`
- see `_PLATFORMS` in `extensions.bzl` (no `windows_arm64`: none of the three
projects publishes one). Each gets its own `@k8s_platform_<platform>`
repository (the requested kustomize/helm archives and kubectl binary, for
that platform only); the `@k8s` hub's `toolchain()`s just alias into
whichever of these Bazel's toolchain resolution actually needs. Since Bazel
fetches external repositories lazily, a given `bazel build`/`bazel run`
invocation only ever downloads the platform repo matching its build graph's
exec platform - typically just one, not all five. kustomize and helm both
publish a `.zip` for Windows and a `.tar.gz` everywhere else;
`rctx.download_and_extract` picks the right extraction method from the URL
itself. kubectl publishes a raw binary directly (no archive at all) - a
plain `rctx.download` fetches it straight to its final filename.

## Checksum mirror

None of `k8s.kustomize(...)`/`k8s.helm(...)`/`k8s.kubectl(...)` need a
`sha256` at all for a version already covered by that tool's own generated
mirror:

- `private/kustomize_versions.bzl` - every kustomize 5.x release
  (`scripts/mirror_kustomize_versions.nu`).
- `private/helm_versions.bzl` - every Helm 3.x release
  (`scripts/mirror_helm_versions.nu`), **GPG-verified** against Helm's own
  published `KEYS` file (kustomize publishes plain checksums with no
  signature alongside at all).
- `private/kubectl_versions.bzl` - every kubectl 1.x release
  (`scripts/mirror_kubectl_versions.nu`), **cosign-verified** (sigstore
  keyless signing - Kubernetes' real integrity mechanism, not GPG) for any
  release that has a signature. Unlike the other two mirrors, this one is
  incremental: only versions *not already in the file* are ever fetched, and
  existing entries are carried over untouched, never re-verified. Real
  cosign verification is over the full binary, not a small checksum file -
  Kubernetes has backported signing to ~180 historical patch releases, and
  verifying all of them for every platform on every refresh would mean
  downloading on the order of 900 full kubectl binaries (tens of GB) each
  time. Only ever verifying genuinely *new* releases as they ship keeps a
  normal refresh cheap (typically zero downloads) without that one-time
  cost - see `scripts/mirror_kubectl_versions.nu`'s own header comment for the
  full reasoning (including the identity/issuer this verifies against, and
  where that came from - it isn't published anywhere as plainly as Helm's
  `KEYS` file). A release with no signature (older releases, or any that
  just don't have one) falls back to a plain-HTTPS checksum fetch, same as
  kustomize's mirror.

`private/versions.bzl` itself is hand-written, not generated - it just
re-exports all three, so `extensions.bzl` has one stable entry point despite
three independent scripts each owning their own file (so they never race or
clobber each other's data if you regenerate more than one at a time).
`extensions.bzl` falls back to whichever mirror applies for a `.kustomize()`/
`.helm()`/`.kubectl()` tag that doesn't supply a `sha256` for a given
platform - an explicit `sha256` on the tag always overrides this, per
platform.

Regenerate any of them with:

```console
$ cd k8s && bazel run //scripts:mirror_kustomize_versions
$ cd k8s && bazel run //scripts:mirror_helm_versions
$ cd k8s && bazel run //scripts:mirror_kubectl_versions  # needs a real `cosign` binary on PATH
```

## Windows

None of the three rules' build actions need a shell - `kustomize_build` uses
kustomize's own `--output` flag directly (or, on its staged path, the
hermetic `nu` for copying files - see Composing helm and kustomize above),
`helm_template` captures `helm template`'s stdout via a hermetic `nu`
(`private/capture_stdout.nu`, see How it works above) rather than a shell
redirection, and `kubectl_binary` is just a
symlink to the resolved binary (`ctx.actions.symlink`, no action script at
all). All run the same way on every platform. Unverified on an actual
Windows machine, the same caveat `rules_terraform`'s own README raises for
its Windows support - the fetched kustomize/helm archives are `.zip`s there
and the kubectl binary is a plain `.exe` (see Supported platforms above),
and the toolchain/action mechanism itself follows the same Bazel APIs
`rules_terraform` already relies on, but real end-to-end behavior is
unverified.

## Layout

- `toolchain.bzl` - `KustomizeInfo`/`kustomize_toolchain` (a kustomize
  binary), `HelmInfo`/`helm_toolchain` (a helm binary), and
  `KubectlInfo`/`kubectl_toolchain` (a kubectl binary).
- `manifest.bzl` - `K8sManifestInfo`, the common provider `helm_template`,
  `kustomize_build`, and `k8s_manifests` all return - see How it works
  above.
- `BUILD.bazel` - the three `toolchain_type`s.
- `extensions.bzl` - the `k8s` module extension; generates the `@k8s` hub
  repo (`toolchain()` aliases per platform, per requested tool, plus a
  ready-to-run `:kubectl` instance if `k8s.kubectl(...)` was declared - see
  Running kubectl above) and, per platform, a `@k8s_platform_<platform>`
  repo (the real `kustomize_toolchain`/`helm_toolchain`/`kubectl_toolchain`,
  lazily fetched only when that platform's toolchains are actually
  selected) from the `.kustomize()`/`.helm()`/`.kubectl()` tags.
- `defs.bzl` - the public API: re-exports `kustomize_build`/`helm_template`/
  `k8s_manifests`/`kubectl_binary`/`K8sManifestInfo` from
  `private/`/`manifest.bzl`. Nothing else should load this module's `.bzl`
  files directly other than `defs.bzl` and `extensions.bzl`.
  - `private/kustomize_build.bzl` - `kustomize_build`'s rule + implementation
    (both the unstaged fast path and the `resources`-triggered staged path).
  - `private/helm_template.bzl` - `helm_template`'s rule + implementation.
  - `private/kubectl_binary.bzl` - `kubectl_binary`'s rule + implementation
    (a plain `ctx.actions.symlink` to the resolved toolchain binary).
  - `private/k8s_manifests.bzl` - `k8s_manifests`'s rule + implementation.
  - `private/capture_stdout.nu` - runs a subprocess (helm) and writes its
    stdout to a file; run via the resolved `nu`, not a shell - see How it
    works above.
  - `private/stage_files.nu` - copies a manifest's worth of `[src, dest]`
    pairs into a declared directory; run via the resolved `nu`. Generic (no
    kustomize-specific logic) - a local copy of the same small script
    `rules_terraform`'s own `private/stage_module.nu` provides, so this
    module stays self-contained.
  - `private/versions.bzl` - hand-written; re-exports the three generated
    checksum mirrors below. See Checksum mirror above.
  - `private/kustomize_versions.bzl`/`helm_versions.bzl`/`kubectl_versions.bzl` -
    each tool's own generated checksum mirror, see Checksum mirror above.
    Not loaded by `defs.bzl`/consumers directly - only `extensions.bzl`
    (via `private/versions.bzl`) reads them.
- `scripts/mirror_kustomize_versions.nu`/`mirror_helm_versions.nu`/
  `mirror_kubectl_versions.nu` (+ a `BUILD.bazel` with one `nu_binary` each) -
  regenerate the three files above; see Checksum mirror above.
- `examples/` - `base`/`overlay` (a kustomize base + overlay demonstrating a
  cross-package `resources: [../base]` reference via a plain `filegroup`),
  `chart` (a minimal Helm chart), `chart_kustomize` (feeds `chart`'s output
  into a `kustomize_build` via `resources`, applying a `namespace`/`labels`
  transform to it - see Composing helm and kustomize above), a top-level
  `k8s_manifests` aggregating all three (`bazel build //:manifests`), and a
  local `kubectl_binary` instance (`bazel run //:kubectl -- version
  --client`) alongside the zero-config `@k8s//:kubectl` `k8s.kubectl(...)`
  itself already generates. Its own separate Bazel module (own
  `MODULE.bazel`, module name `rules_k8s_examples`, listed in this
  directory's own `.bazelignore`), consuming `rules_k8s` via `bazel_dep` +
  `local_path_override` the same way any other consumer would (see Usage
  above). It's also what `.bcr/k8s/presubmit.yml` runs against a released
  version, in the [VJftw/bazel-rules](https://github.com/VJftw/bazel-rules)
  monorepo this module lives in. Build it by `cd`ing in first: `cd examples
  && bazel build //...`.
