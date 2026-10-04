# rules_opa

A small Bazel module providing hermetic `opa_build` (packages Rego policies
into an [Open Policy Agent](https://www.openpolicyagent.org/) bundle),
`opa_eval` (evaluates a Rego query into a single result file), and
`opa_test` (runs `opa test` as a real `bazel test`) rules.

## Quickstart

In your `.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/VJftw/bazel-rules/main/registry/
common --registry=https://bcr.bazel.build
```

In your root `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_opa", version = "0.1.0")

opa = use_extension("@rules_opa//:extensions.bzl", "opa")
opa.version(version = "1.20.2")  # see Checksum mirror below for why no sha256
use_repo(opa, "opa")

register_toolchains("@opa//:all")
```

In a `BUILD.bazel` next to your `.rego` files:

```starlark
load("@rules_opa//:defs.bzl", "opa_test")

opa_test(
    name = "authz_test",
    srcs = ["authz.rego", "authz_test.rego"],
)
```

```console
$ bazel test //:authz_test
```

See [Usage](#usage) below for `opa_build`/`opa_eval` and the full
BCR/`git_override`/local dev options.

## Contents

- [Rules](#rules)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Symlinks and `--follow-symlinks`](#symlinks-and---follow-symlinks)
- [Policy gates](#policy-gates)
- [Supported platforms](#supported-platforms)
- [Checksum mirror](#checksum-mirror)
- [Layout](#layout)

## Rules

- **`opa_build`**: packages `srcs` (Rego policies and `data.json`/
  `data.yaml` files) into a gzipped bundle tarball via `opa build -b
  <root-dir> --follow-symlinks -o <out>`. Defaults to always passing
  `--follow-symlinks` (see Symlinks below) - there's no attr to turn it off,
  unlike `kustomize_build`'s `load_restrictor`, since there's no legitimate
  reason to want the un-followed behavior inside a Bazel action.
- **`opa_eval`**: evaluates a Rego `query` against `srcs` (each passed as
  its own `-d` flag) and, if set, an `input` document, via `opa eval`,
  capturing its result into `out`. `fail_undefined`/`fail_defined` (mapping
  to `opa eval`'s own `--fail`/`--fail-defined`) turn this into a build-time
  policy gate - see Policy gates below.
- **`opa_test`**: runs `opa test <srcs...>` as a real `bazel test` - passes
  iff every `test_*` rule across `srcs` passes.

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
bazel_dep(name = "rules_opa", version = "0.1.0")

opa = use_extension("@rules_opa//:extensions.bzl", "opa")
opa.version(
    version = "1.20.2",  # see https://github.com/open-policy-agent/opa/releases
    sha256 = {...},  # optional, but recommended
)
use_repo(opa, "opa")

register_toolchains("@opa//:all")
```

Before this module has a BCR release, or to develop against an unreleased
change, use a `git_override` (pinned to a commit) or, for a local checkout of
this repo, a `local_path_override` instead of the `bazel_dep` version above -
both need the same `strip_prefix`/`path` pointing at this module's own
`opa/` subdirectory, since this repo is a monorepo of multiple modules:

```starlark
bazel_dep(name = "rules_opa", version = "0.1.0")

# Option A: pin to a commit on the bazel-rules repo.
git_override(
    module_name = "rules_opa",
    remote = "https://github.com/VJftw/bazel-rules.git",
    commit = "<commit-sha>",
    strip_prefix = "opa",
)

# Option B: a local checkout of VJftw/bazel-rules, e.g. for developing
# rules_opa itself alongside a consumer.
local_path_override(
    module_name = "rules_opa",
    path = "../bazel-rules/opa",
)
```

In a `BUILD.bazel` next to your `.rego` files:

```starlark
load("@rules_opa//:defs.bzl", "opa_build", "opa_eval", "opa_test")

opa_build(
    name = "bundle",
    srcs = ["authz.rego", "authz_test.rego"],
)

opa_eval(
    name = "allow_get",
    srcs = ["authz.rego"],
    query = "data.authz.allow",
    input = "input.json",
    fail_undefined = True,
)

opa_test(
    name = "authz_test",
    srcs = ["authz.rego", "authz_test.rego"],
)
```

`bazel build //path:bundle` produces `bundle.tar.gz`; `bazel build
//path:allow_get` produces `allow_get.json` (and fails the build if
`data.authz.allow` is undefined against `input.json`, since
`fail_undefined = True`); `bazel test //path:authz_test` runs the policy's
own test suite.

## How it works

- **Toolchain**: the `opa` binary is wired up through Bazel's
  [toolchain](https://bazel.build/extending/toolchains) mechanism
  (`toolchain_type`, `opa_toolchain`, `toolchain()`), not a hardcoded label -
  resolution follows normal Bazel toolchain rules (exec platform matching,
  registration order, etc), the same as `rules_terraform`'s/`rules_k8s`'s
  own toolchains.
- **Single repository, from `MODULE.bazel`'s perspective**: every requested
  version is addressable through one external repository, `@opa` (see
  `extensions.bzl`) - just one `use_repo(opa, "opa")` and one
  `register_toolchains("@opa//:all")`. Under the hood `@opa` is a thin hub of
  `toolchain()` aliases; the real binary is fetched lazily, one per
  platform, only for whichever platform a given build's toolchain
  resolution actually selects - see Supported platforms below.
- **No archive to extract**: unlike `rules_k8s`'s kustomize/helm (both ship
  a `.tar.gz`/`.zip`), OPA publishes a single raw binary per release - the
  per-platform repository just `rctx.download`s it directly, no
  `download_and_extract` needed.
- **No bash dependency**: `opa_eval`'s build action (the one rule here that
  can't just ask its own CLI to write a single output file - `opa eval` only
  ever writes its result to stdout) and `opa_test`'s runner are both
  Nushell scripts, run via a hermetic `nu` resolved from
  [`rules_nushell`](../nushell/README.md)'s toolchain (`bazel_dep(name =
  "rules_nushell")` in this module's own `MODULE.bazel` - it registers its
  own toolchains and default version, propagating to consumers
  automatically), not a shell - the same approach `rules_terraform` and
  `rules_k8s`'s `helm_template` use. `opa_test`'s executable is a
  `rules_nushell` launcher (a tiny `/bin/sh` script, or a `.bat` on
  Windows) that resolves `nu` and the runner via runfiles - see
  `@rules_nushell//:nu.bzl`.

## Symlinks and `--follow-symlinks`

Bazel always materializes source-file inputs to a sandboxed build action as
symlinks pointing back at the real source tree (not copies) - this is
fundamental to how Bazel exposes sources, not specific to this module's
rules (the same issue `rules_k8s`'s `kustomize_build` documents for
kustomize's own default `--load-restrictor`). `opa build`'s bundle walker
silently skips symlinked files by default - verified empirically: a
symlinked policy directory produces a bundle containing only the
auto-generated `data.json`/`.manifest`, no `.rego` at all, with no error or
warning - which `--follow-symlinks` fixes (also verified empirically).
`opa_build` always passes it. `opa eval`'s `-d`/`--data` loader (used by
`opa_eval`) and `opa test`'s own loader (used by `opa_test`) both follow
symlinks without needing an equivalent flag - only `opa build`'s bundle
loader has this behavior, which is why `opa_eval` is deliberately built on
`-d` rather than `--bundle`.

## Policy gates

`opa_eval`'s `fail_undefined`/`fail_defined` attrs make it usable as a
build-time policy gate, not just a renderer: point `input` at some other
build output (e.g. a `kustomize_build`/`helm_template` result from
`rules_k8s`, or a Terraform plan JSON from `rules_terraform`) and set
`fail_undefined = True` with a `query` that's only defined when the input
satisfies your policy - `bazel build` (and so anything depending on that
target) fails outright if it doesn't, the same way any other failing build
action would. This composes with `bazel test //...`'s network sandboxing
the same way `rules_terraform`'s own `terraform_root_test` does: a passing
gate is also a hermeticity check, since the policy evaluation never touches
the network either.

## Supported platforms

`linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64`, `windows_amd64`
- see `_PLATFORMS` in `extensions.bzl` (no `windows_arm64`: OPA doesn't
publish one). Each gets its own `@opa_platform_<platform>` repository (the
requested binary, for that platform only); the `@opa` hub's `toolchain()`s
just alias into whichever of these Bazel's toolchain resolution actually
needs. Since Bazel fetches external repositories lazily, a given `bazel
build`/`bazel test` invocation only ever downloads the platform repo
matching its build graph's exec platform - typically just one, not all
five. Linux binaries use OPA's `_static` release variant (fully static, no
libc dependency) for maximum portability across exec machines; Darwin and
Windows use OPA's only published variant for those platforms.

## Checksum mirror

`opa.version(version = "1.20.2")` needs no `sha256` at all - `private/versions.bzl`
is a generated `OPA_VERSIONS` dict (version -> platform -> sha256) covering
every OPA 1.x release, and `extensions.bzl` falls back to it for any
platform a `.version()` tag doesn't supply a checksum for itself. An
explicit `sha256` on the tag still always takes precedence, e.g. to pin a
version newer than the last mirror refresh, or a platform OPA hasn't
published yet.

Regenerate it with:

```console
$ cd opa && bazel run //scripts:mirror_opa_versions
```

Plain HTTPS-fetched from OPA's own GitHub release `.sha256` files, not
signature-verified - unlike `rules_terraform`'s own mirror (GPG-verified
against HashiCorp's published signature) or `rules_k8s`'s Helm mirror
(likewise GPG-verified), OPA doesn't publish a signature alongside its
checksums. See `scripts/mirror_opa_versions.nu`'s own header comment for
more.

## Layout

- `toolchain.bzl` - `OpaInfo`/`opa_toolchain` (an opa binary).
- `BUILD.bazel` - the `toolchain_type`.
- `extensions.bzl` - the `opa` module extension; generates the `@opa` hub
  repo (`toolchain()` aliases per platform) and, per platform, an
  `@opa_platform_<platform>` repo (the real `opa_toolchain`, lazily fetched
  only when that platform's toolchain is actually selected) from the
  `.version()` tag.
- `defs.bzl` - the public API: re-exports `opa_build`/`opa_eval`/`opa_test`
  from `private/`. Nothing else should load this module's `.bzl` files
  directly other than `defs.bzl` and `extensions.bzl`.
  - `private/opa_build.bzl` - `opa_build`'s rule + implementation.
  - `private/opa_eval.bzl` - `opa_eval`'s rule + implementation.
  - `private/opa_test.bzl` - `opa_test`'s rule + implementation.
  - `private/capture_stdout.nu` - runs a subprocess (opa eval) and writes
    its stdout to a file; run via the resolved `nu`, not a shell.
  - `private/opa_test_runner_template.nu` - template for `opa_test`'s
    entry point, expanded per-target via `ctx.actions.expand_template`;
    resolves the opa binary and every src's real runtime path via runfiles,
    then runs `opa test`.
  - `private/versions.bzl` - generated `OPA_VERSIONS` checksum mirror, see
    Checksum mirror above. Not loaded by `defs.bzl`/consumers directly -
    only `extensions.bzl` reads it.
- `scripts/mirror_opa_versions.nu` (+ its `BUILD.bazel`, a `nu_binary`) -
  regenerates `private/versions.bzl`; see Checksum mirror above.
- `examples/` - `policy/` (a minimal `authz.rego`/`authz_test.rego` pair,
  wired up as `bundle` (`opa_build`), `allow_get` (`opa_eval`, gated with
  `fail_undefined = True`), and `authz_test` (`opa_test`)). Its own separate
  Bazel module (own `MODULE.bazel`, module name `rules_opa_examples`, listed
  in this directory's own `.bazelignore`), consuming `rules_opa` via
  `bazel_dep` + `local_path_override` the same way any other consumer would
  (see Usage above). It's also what `.bcr/opa/presubmit.yml` runs against a
  released version, in the
  [VJftw/bazel-rules](https://github.com/VJftw/bazel-rules) monorepo this
  module lives in. Build/test it by `cd`ing in first: `cd examples && bazel
  test //...`.
