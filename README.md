# bazel-rules

Monorepo for [VJftw](https://github.com/VJftw)'s Bazel rule sets. Each rule
set lives in its own top-level directory as an independent [bzlmod](https://bazel.build/external/module)
module, publishable to the [Bazel Central Registry](https://registry.bazel.build/)
(BCR) on its own version/release cadence.

## Modules

- [`terraform/`](terraform/) - `rules_terraform`: hermetic, per-target
  Terraform toolchains (see its own [README](terraform/README.md)).

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

`registry/` is updated automatically by `release.yml` (see below) - never
hand-edited - so it only ever contains versions that have a real,
downloadable release asset behind them.

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
  registry/              # self-hosted module registry, see above - populated
                          # by release.yml, not hand-edited
    bazel_registry.json
    modules/
      rules_<module>/
        metadata.json
        <version>/
          MODULE.bazel
          source.json
  .github/
    scripts/
      update_registry.py  # adds one version to registry/, see below
    workflows/
      ci.yml               # bazel test on every module + its examples/
      release.yml           # on a <module>-vX.Y.Z tag: builds that module's
                             # release tarball, attaches it to a GitHub
                             # Release, then updates registry/ for it
```

## Releasing

Each module is released independently, tagged `<module>-vX.Y.Z` (e.g.
`terraform-v0.1.0`), matching the `version` set in that module's own
`MODULE.bazel`. Pushing such a tag runs `.github/workflows/release.yml`,
which:

1. Packages that module's directory into `rules_<module>-<tag>.tar.gz` and
   attaches it to a new GitHub Release.
2. Runs `.github/scripts/update_registry.py`, which computes that archive's
   integrity hash and adds `registry/modules/rules_<module>/<version>/` for
   it (creating `metadata.json` from `.bcr/<module>/metadata.template.json`
   the first time a module is released), then commits and pushes that
   straight to `main` - so `registry/` and real releases can never drift
   apart.

## Publishing to BCR

Independently of the above, once [bazel-contrib/publish-to-bcr](https://github.com/bazel-contrib/publish-to-bcr)
is installed on this repo (a one-time GitHub App install), the same GitHub
Release triggers a pull request against the Bazel Central Registry using the
`.bcr/<module>/*.template.json`/`presubmit.yml` templates here.

## Adding a new rule set

A new top-level directory with its own `MODULE.bazel`, plus a matching entry
in `.bcr/config.yml`'s `moduleRoots` and its own `.bcr/<new-module>/`
template directory (`registry/` needs no new wiring - `release.yml`/
`update_registry.py` already handle any module directory generically).
