# rules_nushell

A small Bazel module providing a hermetic [Nushell](https://www.nushell.sh/)
toolchain, with rules to run Nushell scripts via `bazel run` (`nu_binary`)
and as real `bazel test`s (`nu_test`), and to share Nushell modules between
them (`nu_library`) - plus a small Starlark API (`nu.bzl`) other rulesets
use to run their own build actions and `bazel run`/`bazel test` wrappers
with it, instead of a shell or a Python interpreter (every other module in
this repo does).

## Quickstart

In your `.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/VJftw/bazel-rules/main/registry/
common --registry=https://bcr.bazel.build
```

In your root `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_nushell", version = "0.1.0")

# Optional - rules_nushell requests a default version (0.116.0) and
# registers the toolchains itself. See Usage below.
nushell = use_extension("@rules_nushell//:extensions.bzl", "nushell")
nushell.version(version = "0.116.0")  # see Checksum mirror below for why no sha256
```

In a `BUILD.bazel` next to your `.nu` files:

```starlark
load("@rules_nushell//:defs.bzl", "nu_binary", "nu_test")

nu_binary(
    name = "hello",
    src = "hello.nu",
)

nu_test(
    name = "hello_test",
    src = "hello_test.nu",
)
```

```console
$ bazel run //:hello -- World
$ bazel test //:hello_test
```

See [Usage](#usage) below for the full picture (BCR/`git_override`/local dev
options, `nu_library`).

## Contents

- [Rules](#rules)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Using modules](#using-modules)
- [Using Nushell from another ruleset](#using-nushell-from-another-ruleset)
- [Supported platforms](#supported-platforms)
- [Checksum mirror](#checksum-mirror)
- [Layout](#layout)

## Rules

- **`nu_binary`**: a Nushell script (`src`), runnable via `bazel run
  //path:name -- <args...>` with the pinned `nu`. Any `def main [...]` it
  defines is called with those arguments, the same as `nu <src> <args...>`.
  `deps` lists the `nu_library` targets it `use`s, and `data` any other files
  it needs at runtime (via runfiles).
  The script can also `use runfiles.nu` and resolve any runfile with
  `runfiles rlocation "<repo>/<path>"` (e.g. `"_main/app/name.txt"`).
- **`nu_test`**: the same, run as a real `bazel test` - passes iff the script
  exits 0, so an uncaught error (e.g. a failed assertion from Nushell's own
  `std/assert` module) fails it. The standard `args`/`env` test attributes
  work as usual.
- **`nu_library`**: a reusable set of Nushell modules (`srcs`), that can
  itself `use` another `nu_library` via `deps`. Unlike a plain `filegroup`,
  this composes transitively - a library built on other libraries only needs
  to be listed once by whatever uses it, rather than every consumer
  flattening the whole chain into its own `deps` by hand. See
  `examples/lib/BUILD.bazel`'s `greeting`/`shout` for a two-level example.

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
bazel_dep(name = "rules_nushell", version = "0.1.0")

# Optional - see below.
nushell = use_extension("@rules_nushell//:extensions.bzl", "nushell")
nushell.version(
    version = "0.116.0",
    # Optional for any version in private/versions.bzl - see Checksum mirror.
    sha256 = {
        "linux_amd64": "7b91aeef575080f4b90405ba4512f4ccd0c21a6fbcd99f18bde3272c75213f00",
    },
)
```

Before this module has a BCR release, or to develop against an unreleased
change, use a `git_override` (pinned to a commit) or, for a local checkout of
this repo, a `local_path_override` instead of the `bazel_dep` version above -
both need the same `strip_prefix`/`path` pointing at this module's own
`nushell/` subdirectory, since this repo is a monorepo of multiple modules:

```starlark
bazel_dep(name = "rules_nushell", version = "0.1.0")

# Option A: pin to a commit on the bazel-rules repo.
git_override(
    module_name = "rules_nushell",
    remote = "https://github.com/VJftw/bazel-rules.git",
    commit = "<commit-sha>",
    strip_prefix = "nushell",
)

# Option B: a local checkout of VJftw/bazel-rules, e.g. for developing
# rules_nushell itself alongside a consumer.
local_path_override(
    module_name = "rules_nushell",
    path = "../bazel-rules/nushell",
)
```

Only one Nushell version is active in a build. `rules_nushell` itself
requests a default (0.116.0) and registers the toolchains, so no
`nushell.version` is needed at all. The root module may declare
`nushell.version` at most once, and its request always wins - so a
dependency can't unilaterally change what version the rest of your build
runs scripts with. If the root module declares none, the highest version
any module requests (including `rules_nushell`'s own default, and any
ruleset that uses Nushell internally - see Using Nushell from another
ruleset below) applies instead.

In `BUILD.bazel` files next to your `.nu` files:

```starlark
load("@rules_nushell//:defs.bzl", "nu_binary", "nu_library", "nu_test")

# lib/BUILD.bazel
nu_library(
    name = "greeting",
    srcs = ["greeting.nu"],
    visibility = ["//visibility:public"],
)

# app/BUILD.bazel
nu_binary(
    name = "hello",
    src = "hello.nu",  # `use lib/greeting.nu`
    deps = ["//lib:greeting"],
)

nu_test(
    name = "hello_test",
    src = "hello_test.nu",  # `use std/assert`, `use ../lib/greeting.nu`
    args = ["World"],
    data = ["name.txt"],
    deps = ["//lib:greeting"],
)
```

## How it works

- **Toolchain**: the `nu` binary is wired up through Bazel's
  [toolchain](https://bazel.build/extending/toolchains) mechanism
  (`toolchain_type`, `nu_toolchain`, `toolchain()`), not a hardcoded label -
  see `toolchain.bzl`/`BUILD.bazel`/`extensions.bzl`.
- **Launcher**: `nu_binary`/`nu_test`'s executable is generated by
  `nu_launcher` (see `nu.bzl`): a tiny `/bin/sh` script (a `.bat` on
  Windows, which has no shebang support) that finds `nu` and an entry script
  via runfiles - a symlink tree or just a manifest - exports
  `RUNFILES_DIR`/`RUNFILES_MANIFEST_FILE`, and `exec`s `nu` on it. For
  `nu_binary`/`nu_test`, the entry script (`private/nu_runner_template.nu`,
  expanded per target) then works out the include path (see Using modules)
  and runs `nu --no-config-file --include-path <dirs> <src> <args...>` with
  the same `nu`, propagating its exit code. No Python, and no shell beyond
  that one `/bin/sh` launcher.
- **No user config**: `--no-config-file` means a script behaves the same
  regardless of the invoking user's own Nushell `config.nu`/`env.nu`.
- **Working directory**: as with any `bazel run`/`bazel test`, this is the
  target's runfiles tree, so `data` files are found at their
  workspace-relative path (e.g. `open app/name.txt`). Under `bazel run`,
  `$env.BUILD_WORKING_DIRECTORY` is the directory it was invoked from.

## Using modules

A module from a `nu_library` in `deps` can be `use`d either:

- relative to the script using it, e.g. `use ../lib/greeting.nu` - Nushell
  resolves this against the script's own (runfiles) path, without resolving
  symlinks, so it finds its runfiles siblings; or
- relative to the root of the repository the module lives in, e.g. `use
  lib/greeting.nu` - the launcher passes the root of every repository that
  `src` or one of its `nu_library` deps lives in as `--include-path`, so this
  works the same from any script, at any depth, and across repositories (a
  `nu_library` from another Bazel module resolves relative to *its* own
  root).

Each root is derived at runtime from a file's resolved path minus its own
path within its repository, so this works both with a runfiles symlink tree
and with only a runfiles manifest (`--enable_runfiles=false`, the default on
Windows), in which case the roots are wherever those files really live.

Nushell's own standard library (`use std/assert`, ...) is built into `nu` and
needs no `deps`. Nushell prepends `--include-path` to its default library
directories (under the user's own Nushell config directory), so a module
from `deps` always takes precedence.

## Using Nushell from another ruleset

`nu.bzl` lets another ruleset use this module's hermetic `nu` for its own
rules' build actions and `bazel run`/`bazel test` executables - it's what
`rules_terraform`, `rules_k8s`, `rules_opa` and `rules_hugo` in this repo use
instead of a shell or a Python interpreter. A `bazel_dep(name =
"rules_nushell")` is all that ruleset (or its consumers) needs in
`MODULE.bazel` - this module requests its own default version and registers
its toolchains itself, though a ruleset can also declare the
`nushell.version` it needs (see Usage above for how requests combine).

```starlark
load("@rules_nushell//:nu.bzl", "NU_LAUNCHER_ATTRS", "NU_TOOLCHAIN_TYPE", "nu_launcher", "run_nu")

def _my_rule_impl(ctx):
    # A build action: `nu --no-config-file <script> <arguments...>`.
    run_nu(
        ctx,
        script = ctx.file._my_script,
        outputs = [out],
        inputs = [...],
        tools = [some_tool],
        arguments = ["--out", out.path],  # passed to the script's `def main`
    )

    # A `bazel run`/`bazel test` executable that runs a script with `nu`.
    launcher = nu_launcher(ctx, ctx.file._my_runner)
    return [DefaultInfo(
        executable = launcher.executable,
        runfiles = launcher.runfiles.merge(...),
    )]

my_rule = rule(
    implementation = _my_rule_impl,
    attrs = {...} | NU_LAUNCHER_ATTRS,  # only needed for nu_launcher
    toolchains = [NU_TOOLCHAIN_TYPE],
)
```

A script run by `nu_launcher` can `use runfiles.nu` and resolve its other
runfiles with `runfiles rlocation (...)` - `rlocation_path(ctx, file)` in
`nu.bzl` gives the path to embed for a given `File`. Declare its `def main`
with `--wrapped` to receive arbitrary arguments (including flags) as-is.

## Supported platforms

`linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64`, `windows_amd64`,
`windows_arm64` - see `_PLATFORMS` in `extensions.bzl`. Each gets its own
`@nushell_platform_<platform>` repository (the requested archive, for that
platform only); the `@nushell` hub's `toolchain()`s just alias into whichever
of these Bazel's toolchain resolution actually needs, so a given `bazel
build`/`bazel test` invocation only ever downloads the one matching its exec
platform. Linux uses Nushell's `-musl` builds (fully static, no libc
dependency) for maximum portability across machines.

Only Linux (amd64) has actually been verified - the other platforms are
implemented but untested, the same as Windows in several other modules in
this repo.

## Checksum mirror

`nushell.version(version = "0.116.0")` needs no `sha256` at all -
`private/versions.bzl` is a generated `NUSHELL_VERSIONS` dict (version ->
platform -> sha256) covering every Nushell release that publishes a
`SHA256SUMS` file (0.99.0 onwards; older versions need an explicit
`sha256`), and
`extensions.bzl` falls back to it for any platform a `.version()` tag
doesn't supply a checksum for itself. An explicit `sha256` on the tag still
always takes precedence, e.g. to pin a version newer than the last mirror
refresh.

Regenerate it with:

```console
$ cd nushell && bazel run //scripts:mirror_nushell_versions
```

Plain HTTPS-fetched from Nushell's own GitHub release `SHA256SUMS` files, not
signature-verified - like `rules_hugo`'s own mirror, Nushell doesn't publish
a signature alongside its checksums. See
`scripts/mirror_nushell_versions.nu`'s own header comment for more.

## Layout

- `toolchain.bzl` - `NushellInfo`/`nu_toolchain` (a specific `nu` binary).
- `BUILD.bazel` - the `toolchain_type`.
- `extensions.bzl` - the `nushell` module extension; registers a
  `toolchain()` per supported platform in the `@nushell` hub repository, each
  lazily downloading its own platform's archive.
- `defs.bzl` - the public API: re-exports `nu_binary`, `nu_test` and
  `nu_library`/`NuLibraryInfo` from `private/`. Nothing else should load this
  module's `.bzl` files directly other than `defs.bzl`, `nu.bzl` and
  `extensions.bzl`.
  - `private/nu_binary.bzl` - `nu_binary`'s and `nu_test`'s rules + shared
    implementation.
  - `private/library.bzl` - `NuLibraryInfo`/`nu_library`'s rule +
    implementation.
  - `private/nu_runner_template.nu` - `nu_binary`/`nu_test`'s entry
    script (see How it works and Using modules above).
  - `private/versions.bzl` - generated `NUSHELL_VERSIONS` checksum mirror,
    see Checksum mirror above.
- `nu.bzl` - the Starlark API for other rulesets (`run_nu`, `nu_launcher`,
  `rlocation_path`, `NU_TOOLCHAIN_TYPE`, `NU_LAUNCHER_ATTRS`) - see Using
  Nushell from another ruleset above.
- `runfiles/runfiles.nu` - the `runfiles rlocation` module every
  `nu_launcher`-run script can `use`.
- `scripts/mirror_nushell_versions.nu` (+ its `BUILD.bazel`, a `nu_binary`) -
  regenerates `private/versions.bzl`.
- `examples/` - `//lib:greeting`/`//lib:shout` (a `nu_library` depending on
  another one, `use`d relative to the repository root), `//app:hello` (a
  `nu_binary`) and `//app:hello_test` (a `nu_test` using `std/assert`, both
  kinds of `use`, `args` and `data`). Its own separate Bazel module (own
  `MODULE.bazel`, module name `rules_nushell_examples`, listed in this
  directory's own `.bazelignore`), consuming `rules_nushell` via `bazel_dep`
  + `local_path_override` the same way any other consumer would (see Usage
  above). It's also what `.bcr/nushell/presubmit.yml` runs against a released
  version. Build it by `cd`ing in first: `cd examples && bazel test //...`.
