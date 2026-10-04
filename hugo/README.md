# rules_hugo

A small Bazel module providing a hermetic `hugo_site` macro, which renders a
[Hugo](https://gohugo.io/) static site into a directory of static files (the
`<name>` target) and exposes a directly runnable, pinned `hugo` for local
preview (the `<name>_hugo` target).

## Quickstart

In your `.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/VJftw/bazel-rules/main/registry/
common --registry=https://bcr.bazel.build
```

In your root `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_hugo", version = "0.1.0")

hugo = use_extension("@rules_hugo//:extensions.bzl", "hugo")
hugo.version(version = "0.166.0")  # see Checksum mirror below for why no sha256
use_repo(hugo, "hugo")

register_toolchains("@hugo//:all")
```

In a `BUILD.bazel` next to your site's `hugo.toml`:

```starlark
load("@rules_hugo//:defs.bzl", "hugo_site")

hugo_site(
    name = "public",
    config = "hugo.toml",
    srcs = glob(["content/**", "layouts/**"]),
)
```

```console
$ bazel build //:public
$ bazel run //:public_hugo -- server
```

See [Usage](#usage) below for the full BCR/`git_override`/local dev options.

## Contents

- [Rules](#rules)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Staging and symlinks](#staging-and-symlinks)
- [The `--destination` quirk](#the---destination-quirk)
- [Supported platforms](#supported-platforms)
- [Checksum mirror](#checksum-mirror)
- [Layout](#layout)

## Rules

- **`hugo_site`**: a macro wrapping two underlying rules. `<name>` (`hugo_build`)
  renders `config` + `srcs` into a directory of static files via `hugo
  --source <copy> --destination <out> --noBuildLock ...` - `base_url`
  (`--baseURL`), `environment` (`--environment`, default `"production"`),
  `minify` (`--minify`), and `extra_args` (any other flag, e.g. `--gc`) are
  all passed straight through. `<name>_hugo` (`hugo_binary`) is a directly
  runnable, hermetic `hugo` pinned to the same toolchain - mainly for `bazel
  run //path:<name>_hugo -- server` (live-reloading local preview, not
  something a hermetic *build* action can meaningfully do) and one-off
  subcommands (`hugo new site`, `hugo mod ...`) this module doesn't
  otherwise wrap.

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
bazel_dep(name = "rules_hugo", version = "0.1.0")

hugo = use_extension("@rules_hugo//:extensions.bzl", "hugo")
hugo.version(
    version = "0.166.0",  # see https://github.com/gohugoio/hugo/releases
    sha256 = {...},  # optional, but recommended
)
use_repo(hugo, "hugo")

register_toolchains("@hugo//:all")
```

Before this module has a BCR release, or to develop against an unreleased
change, use a `git_override` (pinned to a commit) or, for a local checkout of
this repo, a `local_path_override` instead of the `bazel_dep` version above -
both need the same `strip_prefix`/`path` pointing at this module's own
`hugo/` subdirectory, since this repo is a monorepo of multiple modules:

```starlark
bazel_dep(name = "rules_hugo", version = "0.1.0")

# Option A: pin to a commit on the bazel-rules repo.
git_override(
    module_name = "rules_hugo",
    remote = "https://github.com/VJftw/bazel-rules.git",
    commit = "<commit-sha>",
    strip_prefix = "hugo",
)

# Option B: a local checkout of VJftw/bazel-rules, e.g. for developing
# rules_hugo itself alongside a consumer.
local_path_override(
    module_name = "rules_hugo",
    path = "../bazel-rules/hugo",
)
```

In a `BUILD.bazel` next to your site's `hugo.toml`:

```starlark
load("@rules_hugo//:defs.bzl", "hugo_site")

hugo_site(
    name = "public",
    config = "hugo.toml",
    srcs = glob([
        "content/**",
        "layouts/**",
    ]),
    minify = True,
)
```

`bazel build //:public` produces a `public/` directory of the rendered site;
`bazel run //:public_hugo -- server` runs a live-reloading local preview
using the same pinned `hugo` version.

## How it works

- **Toolchain**: the `hugo` binary is wired up through Bazel's
  [toolchain](https://bazel.build/extending/toolchains) mechanism
  (`toolchain_type`, `hugo_toolchain`, `toolchain()`), not a hardcoded label -
  resolution follows normal Bazel toolchain rules (exec platform matching,
  registration order, etc), the same as this repo's other modules.
- **Single repository, from `MODULE.bazel`'s perspective**: every requested
  version (and release variant - see below) is addressable through one
  external repository, `@hugo` (see `extensions.bzl`) - just one
  `use_repo(hugo, "hugo")` and one `register_toolchains("@hugo//:all")`.
  Under the hood `@hugo` is a thin hub of `toolchain()` aliases; the real
  binary is fetched lazily, one per platform, only for whichever platform a
  given build's toolchain resolution actually selects - see Supported
  platforms below.
- **Release variant**: Hugo publishes four builds per version - `hugo.version`'s
  `variant` attr picks one (`"extended"`, the default, adds Sass/SCSS support
  most themes expect; `"hugo"` is the plain build; `"extended_withdeploy"`/
  `"withdeploy"` additionally bundle `hugo deploy` cloud-publishing support).
- **Darwin is one universal binary**: unlike every other module in this repo
  (which splits Darwin into `darwin_amd64`/`darwin_arm64`), Hugo ships a
  single fat binary covering both architectures, so there's just one
  `darwin_universal` platform with no `@platforms//cpu:...` constraint.
  Its release is also a macOS `.pkg` installer (Apple's XAR container
  format, wrapping a gzip-compressed cpio archive), not a plain
  `.tar.gz`/`.zip` Bazel's own `download_and_extract` understands - see
  `private/extract_pkg.py`'s own module docstring for the extraction story
  (a real `pkgutil` on an actual Mac, or a pure-Python XAR/gzip parse plus a
  `cpio` shell-out otherwise).

## Staging and symlinks

Bazel always materializes a build action's inputs as symlinks pointing back
at the real files, whether those are original source files or another
action's own outputs - this is fundamental to how Bazel exposes inputs, not
specific to this module (the same issue `rules_opa`/`rules_k8s`'s
`kustomize_build` document for their own tools). Hugo's content/layout
walkers silently skip symlinked files entirely - verified empirically: a
symlinked `layouts`/`content` tree produces a site missing pages that build
correctly from real files, with no error or warning, and there's no
`--follow-symlinks`-equivalent flag to fix it.

The fix is *not* a separate staging build action feeding into a second
build action (`kustomize_build`'s own approach, and this rule's first
attempt) - Bazel re-exposes the first action's output to the second action's
sandbox as symlinks too, regardless of whether the first action wrote real
copies, so the problem just reappears one level removed. Instead,
`hugo_build` (the `hugo_site` macro's own `<name>` target) copies `config` +
`srcs` into a local scratch directory and invokes `hugo` against that copy
within a single action (see `private/run_hugo.nu`, run via a hermetic `nu`
from [`rules_nushell`](../nushell/README.md)'s toolchain rather than a shell)
- real files, on the same local filesystem, never re-exposed across an
action boundary.

## The `--destination` quirk

Hugo resolves a relative `--destination` against its `--source` directory,
not the invoking process's own working directory - the same class of quirk
`rules_plantuml` documents for PlantUML's `-o` flag. `run_hugo.nu` sidesteps
this entirely by resolving both `--source` and `--destination` to absolute
paths before invoking `hugo`, rather than replicating Bazel's own
relative-path math for it.

## Supported platforms

`linux_amd64`, `linux_arm64`, `darwin_universal`, `windows_amd64`,
`windows_arm64` - see `_PLATFORMS` in `extensions.bzl`. Not every release
variant publishes every platform (verified empirically: the default
`"extended"` variant has no `windows_arm64` build) - a platform missing for
the requested variant simply never gets a `toolchain()` registered for it.
Each platform gets its own `@hugo_platform_<platform>` repository (the
requested binary, for that platform only); the `@hugo` hub's `toolchain()`s
just alias into whichever of these Bazel's toolchain resolution actually
needs. Since Bazel fetches external repositories lazily, a given `bazel
build` invocation only ever downloads the platform repo matching its build
graph's exec platform - typically just one, not all five.

## Checksum mirror

`hugo.version(version = "0.166.0")` needs no `sha256` at all - `private/versions.bzl`
is a generated `HUGO_VERSIONS` dict (version -> platform -> sha256) covering
every Hugo release, for the default `"extended"` variant. `extensions.bzl`
falls back to it for any platform a `.version()` tag doesn't supply a
checksum for itself, as long as `variant == "extended"` and no
`url_template` override is set (the mirror only covers that one variant's
official checksums). An explicit `sha256` on the tag always takes
precedence, e.g. to pin a version newer than the last mirror refresh, a
different `variant`, or a platform Hugo hasn't published yet.

Regenerate it with:

```console
$ cd hugo && bazel run //scripts:mirror_hugo_versions
```

Plain HTTPS-fetched from Hugo's own combined `checksums.txt` release asset,
not signature-verified - like `rules_k8s`'s kustomize mirror and unlike
`rules_terraform`'s/Helm's (both GPG-verified), Hugo doesn't publish a
signature alongside its checksums. See `scripts/mirror_hugo_versions.nu`'s
own header comment for more.

## Layout

- `toolchain.bzl` - `HugoInfo`/`hugo_toolchain` (a hugo binary + its version/
  variant).
- `BUILD.bazel` - the `toolchain_type`.
- `extensions.bzl` - the `hugo` module extension; generates the `@hugo` hub
  repo (`toolchain()` aliases per platform) and, per platform, an
  `@hugo_platform_<platform>` repo (the real `hugo_toolchain`, lazily
  fetched only when that platform's toolchain is actually selected) from the
  `.version()` tag.
- `defs.bzl` - the public API: re-exports `hugo_site` from `private/`.
  Nothing else should load this module's `.bzl` files directly other than
  `defs.bzl` and `extensions.bzl`.
  - `private/hugo_site.bzl` - the `hugo_site` macro: wraps `hugo_build`
    (`<name>`) and `hugo_binary` (`<name>_hugo`) into a single call.
  - `private/hugo_build.bzl` - `hugo_build`'s rule + implementation.
  - `private/hugo_binary.bzl` - `hugo_binary`'s rule + implementation.
  - `private/run_hugo.nu` - copies `config` + `srcs` into a local scratch
    directory (dereferencing symlinks) and runs `hugo` against that copy, in
    one action - see Staging and symlinks above.
  - `private/extract_pkg.py` - extracts the `hugo` binary out of a macOS
    `.pkg` installer's `Payload`, for the `darwin_universal` platform - see
    How it works above. Unlike everything else here it runs while *fetching*
    the toolchain (in a repository rule, where toolchains - including
    `rules_nushell`'s - aren't available yet), so it uses whatever `python3`
    is on the host's PATH, and only for that one platform.
  - `private/versions.bzl` - generated `HUGO_VERSIONS` checksum mirror, see
    Checksum mirror above. Not loaded by `defs.bzl`/consumers directly -
    only `extensions.bzl` reads it.
- `scripts/mirror_hugo_versions.nu` (+ its `BUILD.bazel`, a `nu_binary`) -
  regenerates `private/versions.bzl`; see Checksum mirror above.
- `examples/` - `site/` (a minimal Hugo site - `hugo.toml`, one post under
  `content/posts/`, and a `layouts/` covering home/list/single templates -
  wired up as a single `hugo_site(name = "public", ...)`, giving `public`
  (the rendered site) and `public_hugo` (`bazel run //site:public_hugo --
  server`)). Its own separate Bazel module (own `MODULE.bazel`, module name
  `rules_hugo_examples`, listed in this directory's own `.bazelignore`),
  consuming `rules_hugo` via `bazel_dep` +
  `local_path_override` the same way any other consumer would (see Usage
  above). It's also what `.bcr/hugo/presubmit.yml` runs against a released
  version, in the [VJftw/bazel-rules](https://github.com/VJftw/bazel-rules)
  monorepo this module lives in. Build it by `cd`ing in first: `cd examples
  && bazel build //site:public`.
