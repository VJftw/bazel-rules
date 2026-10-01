# bazel-rules

Monorepo for [VJftw](https://github.com/VJftw)'s Bazel rule sets. Each rule
set lives in its own top-level directory as an independent [bzlmod](https://bazel.build/external/module)
module, publishable to the [Bazel Central Registry](https://registry.bazel.build/)
(BCR) on its own version/release cadence. See each module's own README (linked
below) for its own quickstart.

## Contents

- [Modules](#modules)
- [Consuming a module from here directly (before/without BCR)](#consuming-a-module-from-here-directly-beforewithout-bcr)
- [Layout](#layout)
- [Releasing](#releasing)
- [Publishing to BCR](#publishing-to-bcr)
- [Adding a new rule set](#adding-a-new-rule-set)

## Modules

- [`terraform/`](terraform/) - `rules_terraform`: hermetic, per-target
  Terraform toolchains (see its own [README](terraform/README.md)).
- [`plantuml/`](plantuml/) - `rules_plantuml`: hermetic PlantUML diagram
  rendering (see its own [README](plantuml/README.md)).
- [`k8s/`](k8s/) - `rules_k8s`: hermetic Kustomize/Helm/kubectl toolchains,
  with rules to render and compose Kubernetes manifests (see its own
  [README](k8s/README.md)).
- [`opa/`](opa/) - `rules_opa`: hermetic Open Policy Agent toolchain, with
  rules to build bundles, evaluate policies, and run policy tests (see its
  own [README](opa/README.md)).
- [`hugo/`](hugo/) - `rules_hugo`: hermetic Hugo static site generator
  toolchain, with a rule to render a site and a runnable binary for local
  preview (see its own [README](hugo/README.md)).
- [`nushell/`](nushell/) - `rules_nushell`: hermetic Nushell toolchain, with
  rules to run Nushell scripts as binaries and tests, and share modules
  between them (see its own [README](nushell/README.md)).

## Consuming a module from here directly (before/without BCR)

Every released version is also published as a self-hosted [Bazel module
registry](https://bazel.build/external/registry), right in this repo under
`registry/` - so a module here is consumable via a plain `bazel_dep` as soon
as it's released, with no BCR submission/acceptance needed at all (BCR
publishing, below, is a separate, optional step for wider discoverability).

In your own project's `.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/VJftw/bazel-rules/main/registry/
common --registry=https://bcr.bazel.build
```

`--registry` is repeatable and order-sensitive (first match wins), but
listing *any* `--registry` at all stops Bazel from consulting BCR
by default - hence the second line, so modules that aren't in this repo
still resolve normally.

Then in your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_terraform", version = "0.1.0")
```

`registry/` only changes through pull requests - each one that changes a
module adds that module's new version to it (see Releasing below), and
`release.yml` publishes the version's release archive as soon as it merges.

## Layout

```
bazel-rules/
  <module>/            # a bzlmod module: MODULE.bazel names + versions it
    MODULE.bazel
    ...
    examples/           # (optional) a separate bzlmod module consuming
                         # <module> via bazel_dep + local_path_override,
                         # used both as a worked example and as this
                         # module's own test suite
  .bcr/
    config.yml          # moduleRoots - which top-level dirs are BCR modules
    <module>/           # BCR release templates for that module, see below
      metadata.template.json
      presubmit.yml
      source.template.json
  registry/              # self-hosted module registry, see above - updated
                          # in pull requests by .github/scripts/registry.py
    bazel_registry.json
    modules/
      rules_<module>/
        metadata.json
        <version>/
          MODULE.bazel
          source.json
  .github/
    scripts/
      registry.py         # adds a version to registry/, checks pull
                          # requests do, and builds release archives -
                          # see Releasing below
    workflows/
      ci.yml               # bazel test on every module + its examples/
      registry.yml          # on pull requests: `registry.py check`
      release.yml           # on every merge to main: releases each module
                             # version in registry/ that isn't released yet
```

## Releasing

Each module is versioned and released independently: version `X.Y.Z` of
`<module>` is the GitHub Release tagged `<module>-vX.Y.Z` (e.g.
`terraform-v0.1.0`), with that module's release archive,
`rules_<module>-<module>-vX.Y.Z.tar`, attached. There's no separate release
step - a pull request that changes a module also adds its new version to
`registry/`, and merging it releases that version:

1. Give your pull request a [Conventional Commit](https://www.conventionalcommits.org/)
   title - with squash merges, it's the commit message that lands on `main`,
   and it decides every changed module's new version:

   | Title                                | Version bump                                           |
   | ------------------------------------ | ------------------------------------------------------ |
   | `feat(opa)!: ...` (any type with `!`) | major - minor while the module's still `0.x`          |
   | `feat(opa): ...`                     | minor                                                  |
   | `fix(opa): ...`, or any other type   | patch - the module's released contents still changed   |

   It applies to every module the pull request changes - split it up if
   they need different bumps.
2. Stage your changes (`git add`), then run:

   ```console
   $ .github/scripts/registry.py bump
   ```

   For every module whose released contents changed, that sets
   `module(version = ...)` in its `MODULE.bazel` to the version the title
   implies, writes `registry/modules/rules_<module>/<version>/` (its
   `MODULE.bazel` and `source.json`) and adds the version to `metadata.json`
   (created from `.bcr/<module>/metadata.template.json` the first time a
   module is released), and stages all of it - commit it alongside your
   change. It reads the title from the open pull request (via `gh`), or the
   branch's only commit if there's no pull request yet - otherwise, pass
   `--title '...'`. Re-run it whenever you change a module again or retitle
   the pull request; it replaces what it wrote before.

   CI's `version-bumps` job (`registry.py check`, in
   `.github/workflows/registry.yml` - which also re-runs when the title is
   edited) fails the pull request unless the title is a Conventional Commit,
   and every module whose released contents changed has exactly the version
   it implies and an up-to-date `registry/` entry. Changes to only a module's
   `examples/`, its `*.md` docs or its `MODULE.bazel.lock` don't need a new
   version.
3. Once it merges, `.github/workflows/release.yml` releases every module
   version in `registry/` that doesn't have a GitHub Release yet: it rebuilds
   the module's release archive, checks it matches the `registry/` entry's
   integrity hash, and creates the tag and GitHub Release with it attached.

This never pushes to `main`, so it works with branch protection - every
change to `registry/` is reviewed in a pull request like any other.

The registry entry's integrity hash can be computed before the archive is
published because the archive is built reproducibly - from what's staged in
git (not the working tree), with sorted entries and fixed timestamps,
ownership and permissions, as an uncompressed `.tar` (a compressor can produce
different bytes for the same input on different machines) - so the same
change always gives byte-for-byte the same archive, wherever it's built.

Between a merge and `release.yml` finishing, the new version is in `registry/`
but its archive isn't downloadable yet - usually well under a minute. If
`release.yml` fails part-way, re-run it (it also has a manual
`workflow_dispatch` trigger) - it only ever releases what isn't released yet.

## Publishing to BCR

Independently of the above, once [bazel-contrib/publish-to-bcr](https://github.com/bazel-contrib/publish-to-bcr)
is installed on this repo (a one-time GitHub App install), the same GitHub
Release triggers a pull request against the Bazel Central Registry using the
`.bcr/<module>/*.template.json`/`presubmit.yml` templates here.

## Adding a new rule set

A new top-level directory with its own `MODULE.bazel`, plus a matching entry
in `.bcr/config.yml`'s `moduleRoots` and its own `.bcr/<new-module>/`
template directory (`registry/` needs no new wiring - `registry.py`/
`release.yml` already handle any module directory generically; its first
pull request adds its first version, as for any other change).
