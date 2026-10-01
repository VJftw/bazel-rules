# rules_plantuml

A small Bazel module providing a hermetic `plantuml_diagram` rule (renders a
[PlantUML](https://plantuml.com/) `.puml` source into a diagram image as a
build action) and a `plantuml_library` rule (a reusable, transitively
composable set of PlantUML include files).

## Quickstart

In your `.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/VJftw/bazel-rules/main/registry/
common --registry=https://bcr.bazel.build
```

In your root `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_plantuml", version = "0.1.0")

plantuml = use_extension("@rules_plantuml//:extensions.bzl", "plantuml")
plantuml.version(version = "8059")  # see Checksum mirror below for why no sha256
use_repo(plantuml, "plantuml")

register_toolchains("@plantuml//:all")
```

In a `BUILD.bazel` next to your `.puml` files:

```starlark
load("@rules_plantuml//:defs.bzl", "plantuml_diagram")

plantuml_diagram(
    name = "architecture_svg",
    src = "architecture.puml",
)
```

```console
$ bazel build //:architecture_svg
```

See [Usage](#usage) below for the full picture (BCR/`git_override`/local dev
options, `plantuml_library`).

## Contents

- [Rules](#rules)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Checksum mirror](#checksum-mirror)
- [Layout](#layout)

## Rules

- **`plantuml_diagram`**: renders a single `.puml` source into a diagram
  image (`format` - one of `svg` (default), `png`, `eps`, `pdf`). Assumes
  `src` contains exactly one `@startuml`/`@enduml` diagram - PlantUML itself
  supports several diagrams per file, but then names each output after its
  own title, which isn't knowable at analysis time (when Bazel needs to
  already know the declared output's exact name). `deps` lists any other
  files `src` references via `!include` - a plain file, a `filegroup`, or a
  `plantuml_library` (see below) all work.
- **`plantuml_library`**: a reusable set of PlantUML include files (e.g.
  shared styling/macros), that can itself `!include` another
  `plantuml_library` via `deps`. Unlike a plain `filegroup`, this composes
  transitively - a "theme" built from several smaller shared-include
  libraries only needs to be listed once by whatever depends on it, rather
  than every consumer flattening the whole chain into its own `deps` by
  hand. See `examples/BUILD.bazel`'s `theme`/`theme_colors`/`themed_svg` for
  a two-level example.

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
bazel_dep(name = "rules_plantuml", version = "0.1.0")

plantuml = use_extension("@rules_plantuml//:extensions.bzl", "plantuml")
plantuml.version(
    version = "8059",  # see maven-metadata.xml below for available versions
    sha256 = "85eaaad99d64f0733c9ce46edcf176f2e9e14264556d8bf73fc3847059c00995",
)
use_repo(plantuml, "plantuml")

register_toolchains("@plantuml//:all")
```

Before this module has a BCR release, or to develop against an unreleased
change, use a `git_override` (pinned to a commit) or, for a local checkout of
this repo, a `local_path_override` instead of the `bazel_dep` version above -
both need the same `strip_prefix`/`path` pointing at this module's own
`plantuml/` subdirectory, since this repo is a monorepo of multiple modules:

```starlark
bazel_dep(name = "rules_plantuml", version = "0.1.0")

# Option A: pin to a commit on the bazel-rules repo.
git_override(
    module_name = "rules_plantuml",
    remote = "https://github.com/VJftw/bazel-rules.git",
    commit = "<commit-sha>",
    strip_prefix = "plantuml",
)

# Option B: a local checkout of VJftw/bazel-rules, e.g. for developing
# rules_plantuml itself alongside a consumer.
local_path_override(
    module_name = "rules_plantuml",
    path = "../bazel-rules/plantuml",
)
```

`plantuml.version` is declared exactly once, from the root module only - the
same way `terraform.default_script` works in `rules_terraform` - so a
dependency can't unilaterally change what version the rest of your build
renders diagrams with. Available versions are listed at
https://repo1.maven.org/maven2/net/sourceforge/plantuml/plantuml/maven-metadata.xml
(PlantUML's Maven Central artifact); `sha256` is optional but recommended
for supply-chain integrity.

In a `BUILD.bazel` next to your `.puml` files:

```starlark
load("@rules_plantuml//:defs.bzl", "plantuml_diagram")

plantuml_diagram(
    name = "architecture_svg",
    src = "architecture.puml",
    format = "svg",
)
```

`bazel build //path:architecture_svg` renders `architecture.puml` into
`architecture.svg` using the pinned PlantUML version, via a Bazel-fetched
JVM.

## How it works

- **Toolchain**: the PlantUML jar is wired up through Bazel's
  [toolchain](https://bazel.build/extending/toolchains) mechanism
  (`toolchain_type`, `plantuml_toolchain`, `toolchain()`), not a hardcoded
  label - see `toolchain.bzl`/`BUILD.bazel`.
- **No system Java required**: PlantUML is a plain, platform-independent
  jar, run via a JVM resolved from Bazel's own built-in
  `@bazel_tools//tools/jdk:runtime_toolchain_type` toolchain -
  `plantuml_diagram` applies a transition pinning
  `--java_runtime_version=remotejdk_21` for its own action, so it always
  renders with the same Bazel-fetched JVM regardless of whether (or what)
  Java is installed on the machine running Bazel - see
  `private/diagram.bzl`.
- **No `bazel_dep` on `rules_java` needed**: since this only needs a plain
  JVM (no compilation), Bazel's own built-in Java toolchain support is
  enough - no extra dependency just to run a jar.

## Checksum mirror

`plantuml.version(version = "8059")` needs no `sha256` at all -
`private/versions.bzl` is a generated `PLANTUML_VERSIONS` dict (version ->
sha256) covering every published PlantUML release, and `extensions.bzl`
falls back to it for a `.version()` tag that doesn't supply one. An explicit
`sha256` on the tag still always takes precedence, e.g. to pin a version
newer than the last mirror refresh.

Regenerate it with:

```console
$ cd plantuml && bazel run //scripts:mirror_plantuml_versions
```

Unlike every other mirror in this repo, Maven Central publishes no
checksum or signature file for this artifact at all (verified empirically),
so this one is computed by downloading each version's own jar and hashing
it locally, rather than fetching/verifying a published one - see
`scripts/mirror_plantuml_versions.nu`'s own header comment for more.
[`rules_nushell`](../nushell/README.md) (which runs that script) is a
`dev_dependency` of this module's own `MODULE.bazel` for this reason -
`plantuml_diagram`/`plantuml_library` themselves are pure JVM and need no
Nushell at all, so a consumer of this module never sees that dependency.

## Layout

- `toolchain.bzl` - `PlantUMLInfo`/`plantuml_toolchain` (a specific PlantUML
  jar).
- `BUILD.bazel` - the `toolchain_type`.
- `extensions.bzl` - the `plantuml` module extension; downloads the
  requested jar from Maven Central (or `url_template`, if overridden) into
  the generated `@plantuml` repository, wrapped by a `plantuml_toolchain` +
  `toolchain()`.
- `defs.bzl` - the public API: re-exports `plantuml_diagram` and
  `plantuml_library`/`PlantUMLLibraryInfo` from `private/`. Nothing else
  should load this module's `.bzl` files directly other than `defs.bzl` and
  `extensions.bzl`.
  - `private/diagram.bzl` - `plantuml_diagram`'s rule + implementation,
    including the `--java_runtime_version` transition and the
    `-o`-relative-to-`src`-directory workaround (PlantUML resolves a
    relative `-o` against its input file's own directory, not the action's
    cwd - see the comment on `_relative_output_dir`).
  - `private/library.bzl` - `PlantUMLLibraryInfo`/`plantuml_library`'s rule +
    implementation: aggregates its own `srcs` plus the transitive
    `transitive_srcs` of any `deps` into `DefaultInfo.files`, which is all
    `plantuml_diagram`/`plantuml_library`'s own `deps` attributes need to
    pick up the whole chain via plain `ctx.files`/`ctx.attr` label-list
    resolution - no special-casing needed on the consuming side.
  - `private/versions.bzl` - generated `PLANTUML_VERSIONS` checksum mirror,
    see Checksum mirror above. Not loaded by `defs.bzl`/consumers directly -
    only `extensions.bzl` reads it.
- `scripts/mirror_plantuml_versions.nu` (+ its `BUILD.bazel`, a `nu_binary`) -
  regenerates `private/versions.bzl`; see Checksum mirror above.
- `examples/` - `hello_svg`/`hello_png`, rendering a trivial sequence
  diagram in both formats; `theme_colors`/`theme`/`themed_svg`, demonstrating
  a `plantuml_library` depending on another one, with `themed_svg` only
  listing `theme` in its own `deps`. Its own separate Bazel module (own
  `MODULE.bazel`, module name `rules_plantuml_examples`, listed in this
  directory's own `.bazelignore`), consuming `rules_plantuml` via
  `bazel_dep` + `local_path_override` the same way any other consumer would
  (see Usage above). It's also what `.bcr/plantuml/presubmit.yml` runs
  against a released version, in the
  [VJftw/bazel-rules](https://github.com/VJftw/bazel-rules) monorepo this
  module lives in. Build it by `cd`ing in first: `cd examples && bazel
  build //...`.
