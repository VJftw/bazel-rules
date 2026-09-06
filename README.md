# bazel-rules

Monorepo for [VJftw](https://github.com/VJftw)'s Bazel rule sets. Each rule
set lives in its own top-level directory as an independent [bzlmod](https://bazel.build/external/module)
module, publishable to the [Bazel Central Registry](https://registry.bazel.build/)
(BCR) on its own version/release cadence.

## Modules

- [`terraform/`](terraform/) - `rules_terraform`: hermetic, per-target
  Terraform toolchains (see its own [README](terraform/README.md)).

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
  .github/workflows/
    ci.yml               # bazel test on every module + its examples/
    release.yml           # builds a per-module release tarball on
                           # <module>-vX.Y.Z tags, for publish-to-bcr to pick up
```

## Releasing / publishing to BCR

Each module is released independently, tagged `<module>-vX.Y.Z` (e.g.
`terraform-v0.1.0`), matching the `version` set in that module's own
`MODULE.bazel`. Pushing such a tag:

1. Triggers `.github/workflows/release.yml`, which packages that module's
   directory into a `rules_<module>-<tag>.tar.gz` and attaches it to a
   GitHub Release.
2. Once [bazel-contrib/publish-to-bcr](https://github.com/bazel-contrib/publish-to-bcr)
   is installed on this repo (a one-time GitHub App install), that release
   triggers a pull request against the Bazel Central Registry using the
   `.bcr/<module>/*.template.json`/`presubmit.yml` templates here.

Adding a new rule set later means: a new top-level directory with its own
`MODULE.bazel`, a matching entry in `.bcr/config.yml`'s `moduleRoots`, and its
own `.bcr/<new-module>/` template directory.
