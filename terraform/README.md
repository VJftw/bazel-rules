# rules_terraform

A small Bazel module providing hermetic, per-target Terraform toolchains.

- **Toolchains**: Terraform binaries and provider plugins are both wired up
  through Bazel's [toolchain](https://bazel.build/extending/toolchains)
  mechanism (`toolchain_type`, `terraform_toolchain`,
  `terraform_provider_mirror_toolchain`, `toolchain()`), not hardcoded labels,
  so resolution follows normal Bazel toolchain rules (exec platform matching,
  registration order, etc).
- **Single repository, from `MODULE.bazel`'s perspective**: every requested
  Terraform version and provider plugin is addressable through one external
  repository, `@terraform` (see `extensions.bzl`) - there's no per-version,
  per-provider, or per-platform repo to wire up yourself, just one
  `use_repo(terraform, "terraform")` and one
  `register_toolchains("@terraform//:all")`. Under the hood `@terraform` is a
  thin hub of `toolchain()` aliases; the actual archives are fetched lazily,
  one real repository per platform, only for whichever platform(s) a given
  build's toolchain resolution actually selects - see Supported platforms
  below.
- **Multiple versions, different targets, same build**: both rules take a
  `version` attribute and apply a
  [Starlark transition](https://bazel.build/extending/config#user-defined-transitions)
  that sets the `//:version` build setting for that target's own
  configuration before toolchain resolution runs. A `legacy` root pinned to
  `1.4.0` and a `new` root pinned to `1.6.0` (see `examples/`)
  each resolve to their own toolchain in the same `bazel build`/`bazel run`
  invocation - no need to pass `--//build/rules/terraform:version` on the
  command line or run separate builds. Each `terraform_module` pins its own
  `version` too, independent of any `terraform_root` depending on it - see
  Rules below.
- **Hermetic providers**: provider plugins requested via `terraform.provider`
  tags are fetched once, unpacked into a Terraform
  [filesystem mirror](https://developer.hashicorp.com/terraform/cli/config/config-file#explicit-installation-method-configuration)
  layout, and pointed to via a generated `.terraformrc`
  (`TF_CLI_CONFIG_FILE`) with `direct` installation disabled - so
  `terraform init` never needs network access, and both the build-time
  validate action and `bazel run ... -- plan/apply` run fully sandboxed.
- **Hermetic third-party modules**: registry/git modules requested via
  `terraform.module` tags are fetched once and pre-declared in a fabricated
  `.terraform/modules/modules.json`, so `init` skips resolving them over the
  network too - see Third-party modules below.
- **In-repo providers**: `terraform_local_provider` adds an in-repo-built
  provider plugin binary (e.g. a `go_binary`) to the same offline mirror as
  fetched providers, via a `local_providers` attribute - so a provider you're
  developing alongside your Terraform config never needs a published release
  to be usable - see Providers below.
- **OpenTofu (or any compatible fork)**: `terraform.version`'s `url_template`/
  `bin_name` let a "version" mean a build from somewhere other than
  HashiCorp - see Checksum mirror below.
- **No bash dependency**: every build action (staging, `init`/`validate`)
  and `terraform_root`'s `bazel run`/`terraform_root_test` runtime wrapper
  are Python, executed via a hermetic interpreter resolved from
  `rules_python`'s toolchain (`bazel_dep(name = "rules_python")` +
  `python.toolchain(...)` in this module's own `MODULE.bazel` - propagates
  to consumers automatically via normal bzlmod toolchain registration, no
  extra `MODULE.bazel` wiring needed on your side). See Windows below for
  what this means for that platform specifically.

## Rules

- **`terraform_module`**: a reusable Terraform module. Takes a `version` and
  collects its own `srcs` plus the transitive `srcs` of any `deps` (other
  `terraform_module` targets it references via local, relative-path
  `source = "../foo"` module blocks) and any `registry_modules` (third-party
  registry/git modules - see Third-party modules below), and runs `terraform
  init && terraform validate` against them as a build action, pinned to its
  own `version` - building the target (directly, or transitively as someone
  else's `deps`) validates it.
- **`terraform_root`**: a `terraform_module` that is also a Root Terraform
  Module - it's executable, so `bazel run //path:name -- plan` (or `init`,
  `apply`, ...) runs its pinned Terraform version against it. Building it
  validates its own files and its deps' files too, against that same pinned
  version.

Each target's `version` only pins *its own* validate/run action; it's not
compared against, or propagated to, `deps` or dependents. A `terraform_module`
pinned to `1.4.0` used as a `terraform_root`'s dep at `version = "1.6.0"`
validates itself at 1.4.0, while the root still validates and runs the whole
tree (including that module's files) at 1.6.0 - both are fine, and Bazel
raises no error if they differ, since real Terraform modules aren't tied to a
specific CLI version anyway. Giving `terraform_module` its own `version` is
mainly so it can be built standalone (`bazel build //path:module`) without
having to pass `--@rules_terraform//:version=X.Y.Z` on the command line.

## Custom workflows

`bazel run //path:legacy -- plan` always hands off to a script, once staging,
the provider mirror, and manifest fabrication are set up - by default,
`rules_terraform`'s own built-in one, which just runs auto-`init` (for
`plan`/`apply`/etc) then execs `terraform` itself, i.e. exactly what's
described above.

`terraform.default_script(target = ...)` (a `terraform` module extension tag,
in `MODULE.bazel`) points every `terraform_root` in the build at a different
script instead - useful for anything this module doesn't itself support: an
approval gate before `apply`, a notification on completion, wrapping several
terraform invocations in one `bazel run`, etc. It's workspace-wide, not
per-target - there's no way to give one `terraform_root` a different script
than the rest of the build.

```starlark
terraform = use_extension("@rules_terraform//:extensions.bzl", "terraform")
terraform.default_script(target = "//tools:my_workflow")
use_repo(terraform, "terraform")
```

Only takes effect from the root module (declaring it more than once, even
across separate `bazel_dep`s, is a build error) - one from a dependency is
silently ignored, so a library you depend on can't unilaterally change what
every `terraform_root` in your build does.

Your script receives:

- `TF_BIN` - the resolved `terraform` (or `tofu`, ...) binary, as an env var.
- `TF_MODULE_DIR` - a writable, execroot-scoped scratch copy of the module,
  as an env var - safe to `init`/`plan`/`apply` against; never the real
  source tree. Also the script's own current working directory (`bazel
  run`'s own cwd is Bazel's execroot, not anything meaningful to a caller -
  so the runner overwrites it with this instead of leaving it), so a
  relative path resolves against it directly with no `-chdir=...` needed.
- `PATH`, prepended with an entry named after whatever `TF_BIN` actually
  resolved to (`terraform`, or `tofu`/whatever else a non-default `bin_name`
  chose) - so a plain `terraform plan` (or `tofu plan`, etc) works too,
  without needing `$TF_BIN` at all.
- `TF_LABEL` - the `terraform_root` target's own canonical label (e.g.
  `//path/to:name`), as an env var - since one script now runs for every
  root in the build (there's no per-target `script` anymore), this is how it
  tells them apart, e.g. to scope state, pick a notification channel, or
  build an approval-gate message.
- `TF_ROOT_NAME`/`TF_ROOT_PACKAGE` - that same label's name and package,
  already split out, as env vars.
- `TF_VERSION` - the target's pinned Terraform `version`, as an env var.
- everything after `--` on the `bazel run` command line, as its own `argv`
  (e.g. `plan` above) - `terraform_root`'s own auto-`init` doesn't run for
  you, since your script owns the whole command; call `$TF_BIN init ...`
  yourself if you need it.

`target` must resolve to exactly one output file (`DefaultInfo.files`) and be
executable at runtime - an `sh_binary`/`py_binary`/other executable rule, or a
plain source file checked into the repo with its executable bit set
(`chmod +x` it in the repo; Bazel preserves that bit for a plain file
dependency).

`terraform_root`'s own `env` attr sets fixed environment variables for
whichever script it hands off to - e.g. for a `TF_LOG` level or a profile
name that this target always needs, checked into the `BUILD.bazel` file
rather than set ad hoc by every caller:

```starlark
terraform_root(
    name = "legacy",
    srcs = ["main.tf"],
    env = {"TF_LOG": "INFO", "AWS_PROFILE": "legacy-account"},
    version = "1.4.0",
)
```

`env` entries take precedence over whatever's already in the invoking
shell's environment (so they're for fixed target config, not a default
callers can override per-invocation) - but `TF_BIN`/`TF_MODULE_DIR`/
`TF_CLI_CONFIG_FILE` (set by the runner itself) always win over `env`, since
those are structural rather than user config. Ad hoc variables not declared
in `env` still pass through from the invoking shell as normal (e.g.
`MY_VAR=x bazel run //path:legacy -- plan`) - `env` only matters for names
you want fixed regardless of caller.

```console
$ cat my_workflow.sh
#!/usr/bin/env bash
set -euo pipefail
terraform init -input=false -no-color
terraform "$@"
echo "done: $*" | mail -s "terraform $*" me@example.com

$ bazel run //path:legacy -- apply
```

## Providers

Every provider plugin your modules use has to be declared once via
`terraform.provider` (see Usage below) - there's no fallback to the public
registry over the network. If a `.tf` file references a provider that wasn't
declared this way, `terraform init` fails loudly rather than silently
reaching out to the network.

By default only HashiCorp-published providers are supported (source
`hashicorp/<name>`, fetched from `releases.hashicorp.com` - the same
convention the Terraform CLI binary itself is fetched with) - third-party/
community providers use the full Terraform Registry API protocol to resolve
download URLs, which this extension doesn't implement. See below for how to
fetch those anyway, via an explicit `url_template`.

### Third-party providers

A `terraform.provider` can point somewhere other than
`releases.hashicorp.com`, via `url_template` (a string with literal
`{namespace}`/`{name}`/`{version}`/`{platform}` placeholders, substituted the
same way for every platform) - e.g.
[Cloudflare's provider](https://github.com/cloudflare/terraform-provider-cloudflare),
a genuine third-party (non-HashiCorp) provider:

```starlark
terraform.provider(
    source = "cloudflare/cloudflare",
    version = "5.24.0",
    url_template = "https://github.com/cloudflare/terraform-provider-cloudflare/releases/download/v{version}/terraform-provider-cloudflare_{version}_{platform}.zip",
    sha256 = {
        "linux_amd64": "...",
        "linux_arm64": "...",
        "darwin_amd64": "...",
        "darwin_arm64": "...",
        "windows_amd64": "...",
    },
)
```

`sha256` is required here - there's no checksum mirror for providers (unlike
`terraform.version`'s HashiCorp-specific one), so it's always required for
every provider regardless of source. Everything else (the offline provider
mirror, `terraform init` skipping the network) works exactly the same either
way; verified against a real Cloudflare 5.24.0 provider release (see
`examples/cloudflare`) - `cd examples && bazel test
//cloudflare:cloudflare_plan_test` genuinely installs and initializes the
`cloudflare/cloudflare` provider from the offline mirror, inside Bazel's
network-sandboxed test environment.

### In-repo (local) providers

A provider doesn't have to be fetched from anywhere - `terraform_local_provider`
(`local_provider.bzl`) wraps an in-repo-built provider plugin binary (e.g. a
`go_binary` implementing the Terraform plugin protocol) into the same
filesystem-mirror layout a fetched `terraform.provider` produces, so `terraform
init` picks it up from the offline mirror exactly the same way - no published
release, no registry, no network fetch, ever. Reference it from a
`terraform_module`/`terraform_root`'s `local_providers` attribute, alongside
whatever `terraform.provider` tags already provide:

```starlark
go_binary(
    name = "myprovider_bin",
    embed = [":myprovider_lib"],
)

terraform_local_provider(
    name = "myprovider",
    binary = ":myprovider_bin",
    source = "myorg/myprovider",
    version = "0.1.0",
    hostname = "local",  # avoid colliding with a real registry.terraform.io namespace
)

terraform_root(
    name = "root",
    srcs = ["main.tf"],
    local_providers = [":myprovider"],
    version = "1.6.0",
)
```

with a matching `required_providers` block:

```hcl
terraform {
  required_providers {
    myprovider = {
      source  = "local/myorg/myprovider"
      version = "0.1.0"
    }
  }
}
```

`binary` is built in the exec configuration (like a `terraform_toolchain`'s
own `terraform_bin`), so it's automatically built for whichever platform
actually runs `terraform` (the machine doing the build, or running `bazel
run`), not the build's target platform. Multiple provider-mirror sources (the
toolchain-fetched mirror, plus one per `local_providers` entry) are wired into
Terraform's CLI config as separate `filesystem_mirror` blocks - see
`private/common.bzl`'s `collect_provider_mirror_sources` - so a local provider
composes freely with fetched ones, including a local provider under the same
`hashicorp`/`registry.terraform.io` namespace as one this extension would
otherwise fetch, e.g. to develop a fork of a published provider without a
released build.

## Third-party modules

A `.tf` file can reference a registry or git-hosted module (as opposed to a
local, relative-path one covered by `deps`) - e.g.:

```hcl
module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"
}
```

Normally `terraform init` resolves that over the network. To make it
hermetic, declare it once via `terraform.module` (see Usage below), then wire
it into the consuming `terraform_module`/`terraform_root`'s `registry_modules`
attribute, keyed by the module call's local name (`"label"` above):

```starlark
terraform_root(
    name = "thirdparty",
    srcs = ["main.tf"],
    registry_modules = {
        "label": "@terraform//:module_label",
    },
    version = "1.6.0",
)
```

Under the hood (`_stage_module`/`_registry_modules_setup` in `defs.bzl`), the
fetched module's files are staged alongside the consumer's own files, and a
`.terraform/modules/modules.json` manifest is fabricated pointing at them -
verified empirically (with a real registry module, network forced to fail)
that `terraform init` and `plan` both then succeed without ever reaching the
registry.

Like providers, this doesn't call the Terraform Registry API to resolve a
download URL - you supply a concrete, directly-downloadable archive URL
yourself (`terraform.module`'s `url` attr), resolved once via:

```console
$ curl -sD - https://registry.terraform.io/v1/modules/<namespace>/<name>/<provider>/<version>/download
x-terraform-get: git::https://github.com/<owner>/<repo>?ref=<ref>
```

For a GitHub-backed module resolving to a `git::` address like that, the
equivalent downloadable archive is
`https://github.com/<owner>/<repo>/archive/<ref>.tar.gz` (`strip_prefix
= "<repo>-<ref>"`).

### Third-party modules referenced through a local `deps` module

A local `terraform_module` in your `deps` (e.g. `network`) can have its own
`registry_modules` too. If it does, wire `deps` as a dict keyed by the local
module call name (the label of the `module "..." { ... }` block that
references it, e.g. `{"network": "//path:network"}`) and also set
`dep_sources`, giving the *exact* `source = "..."` string as written in your
own `.tf` for that call (e.g. `dep_sources = {"network": "../network"}`):

```starlark
terraform_root(
    name = "legacy",
    srcs = ["main.tf"],
    deps = {"network": "//path:network"},
    dep_sources = {"network": "../network"},
    version = "1.4.0",
)
```

`dep_sources` is only required for a `deps` entry that has something hermetic
(a `registry_modules`, at any depth) reachable through it - a plain local dep
needs no entry, since Terraform resolves it for free either way. It matters
because Terraform keys nested manifest entries by dotted call-name chains
(verified empirically: a real nested registry module inside `network`, used
by `legacy`, gets the manifest key `network.label`) - and an ancestor entry
for `network` itself has to be pre-populated with *exactly* the right
`source` string, or Terraform re-discovers that local module and silently
wipes out whatever was pre-populated beneath it, even if the nested entry's
own content was otherwise correct. `terraform_module`/`terraform_root`
propagate this recursively through `TerraformModuleInfo`, so it composes
through any depth of local `deps` chains automatically - only the *first*
level in the chain (whichever target's own `.tf` writes the `source =
"../foo"` string) needs `dep_sources` set for each hop.

### A third-party module that itself depends on further third-party modules

Vendored `.tf` code sometimes calls another registry/git module internally.
The extension can't discover that on its own (it never parses `.tf` content),
so declare the inner one with its own `terraform.module` tag too, then
reference it from the outer one's tag via `nested`, keyed by the local module
call name used *inside* the outer module's own source:

```starlark
terraform.module(
    name = "vpc",
    source = "registry.terraform.io/some-org/vpc/aws",
    ...,
    nested = {"endpoints": "vpc_endpoints"},  # "vpc_endpoints" is another .module() name
)
terraform.module(
    name = "vpc_endpoints",
    source = "registry.terraform.io/some-org/vpc-endpoints/aws",
    ...,
)
```

This composes with the `deps`/nested-module-of-a-module cases above - a
`registry_modules` entry's own vendor-declared `nested` chain is expanded
recursively wherever it's used, however deep.

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
bazel_dep(name = "rules_terraform", version = "0.1.0")

terraform = use_extension("@rules_terraform//:extensions.bzl", "terraform")

# No `sha256` needed for either - both are 1.x versions already covered by
# the generated checksum mirror (private/versions.bzl) - see Checksum
# mirror below.
terraform.version(version = "1.4.0")
terraform.version(version = "1.6.0")

terraform.provider(
    source = "hashicorp/random",
    version = "3.6.0",
    sha256 = {...},  # optional, but recommended
)
terraform.module(
    name = "label",
    source = "registry.terraform.io/cloudposse/label/null",
    version = "0.25.0",
    url = "https://github.com/cloudposse/terraform-null-label/archive/<ref>.tar.gz",
    sha256 = "...",
    strip_prefix = "terraform-null-label-<ref>",
)
use_repo(terraform, "terraform")

register_toolchains("@terraform//:all")
```

Before this module has a BCR release, or to develop against an unreleased
change, use a `git_override` (pinned to a commit) or, for a local checkout of
this repo, a `local_path_override` instead of the `bazel_dep` version above -
both need the same `strip_prefix`/`path` pointing at this module's own
`terraform/` subdirectory, since this repo is a monorepo of multiple modules:

```starlark
bazel_dep(name = "rules_terraform", version = "0.1.0")

# Option A: pin to a commit on the bazel-rules repo.
git_override(
    module_name = "rules_terraform",
    remote = "https://github.com/VJftw/bazel-rules.git",
    commit = "<commit-sha>",
    strip_prefix = "terraform",
)

# Option B: a local checkout of VJftw/bazel-rules, e.g. for developing
# rules_terraform itself alongside a consumer.
local_path_override(
    module_name = "rules_terraform",
    path = "../bazel-rules/terraform",
)
```

In a `BUILD.bazel` next to your `.tf` files:

```starlark
load("@rules_terraform//:defs.bzl", "terraform_module", "terraform_root")

# A shared module, referenced by root modules below via `source = "../network"`.
terraform_module(
    name = "network",
    srcs = ["main.tf"],
    version = "1.4.0",
    visibility = ["//visibility:public"],
)

terraform_root(
    name = "legacy",
    srcs = ["main.tf"],
    deps = {"network": ":network"},
    version = "1.4.0",
)
```

`bazel build //path:legacy` runs `terraform init && terraform validate`
against `legacy` and `network` using Terraform 1.4.0, resolving any
`required_providers` from the offline mirror. `bazel run //path:legacy --
plan` runs Terraform 1.4.0's `plan` against it, same mirror. A sibling
`terraform_root` with `version = "1.6.0"` does the same with 1.6.0, in the
same build/invocation, with no other changes required.

## Testing

`bazel test //...` sandboxes execution with no network access by default
(unless a test opts into `tags = ["requires-network"]`), which makes it a
convenient way to enforce hermeticity as an ongoing regression test rather
than a one-off manual check.

- **`terraform_root_test`** (`testing.bzl`): runs `terraform plan` (or
  whatever `tf_args` says) against an already-built `terraform_root`, as a
  real `bazel test`:

  ```starlark
  load("@rules_terraform//:testing.bzl", "terraform_root_test")

  terraform_root_test(
      name = "legacy_plan_test",
      root = ":legacy",
      size = "small",
  )
  ```

  A pass means the whole hermetic pipeline - toolchain, provider mirror, any
  `registry_modules`/`dep_sources` manifest fabrication, auto-init - worked
  without ever reaching the network; a network dependency sneaking back in
  would show up as a real, sandboxed test failure. See `examples/`
  for one per root (`legacy_plan_test`, `new_plan_test`,
  `thirdparty_plan_test`) - and `network_build_test`, a plain
  `@bazel_skylib//rules:build_test.bzl` for `network` (a `terraform_module`,
  not a root, so there's no `plan` to run - this just asserts it builds).

- **Analysis tests** (`@bazel_skylib//lib:unittest.bzl`'s `analysistest`) for
  the Starlark logic itself, not needing a real Terraform run - see
  `examples/tests/`. `missing_dep_sources_test`/
  `ok_dep_sources_test` assert that a `deps` entry with hermetic
  `registry_modules` beneath it fails analysis with a `dep_sources`-mentioning
  error when that's missing, and succeeds when it's supplied.

`examples/` is its own bzlmod module (`rules_terraform_examples`, own
`MODULE.bazel`, consuming `rules_terraform` via `bazel_dep` +
`local_path_override` like any other consumer would - see Layout below), so
run the whole suite from inside it: `cd examples && bazel test //...`.

## Checksum mirror

`terraform.version(version = "1.4.0")` needs no `sha256` at all - unlike
`terraform.provider`/`terraform.module`, which always need one supplied
explicitly. `private/versions.bzl` is a generated `TERRAFORM_VERSIONS` dict
(version -> platform -> sha256) covering every Terraform 1.x release, and
`extensions.bzl` falls back to it for any platform a `.version()` tag doesn't
supply a checksum for itself. An explicit `sha256` on the tag still always
takes precedence, e.g. to pin a version newer than the last mirror refresh,
or a platform HashiCorp hasn't published yet.

Regenerate it with:

```console
$ cd terraform && bazel run //scripts:mirror_terraform_versions
```

(`scripts/mirror_terraform_versions.py`, logic originally adapted from
[VJftw/bazel_terraform](https://github.com/VJftw/bazel_terraform/blob/main/scripts/mirror_terraform_releases.sh) -
runs via the same hermetic Python toolchain as everything else in this
module rather than bash, though it still shells out to a real `gpg` binary
on PATH for signature verification). It scrapes releases.hashicorp.com's 1.x
release list, downloads each
release's `SHA256SUMS` file, and verifies it against HashiCorp's published
GPG signature (fetched fresh each run from
`https://www.hashicorp.com/.well-known/pgp-key.txt`, key `72D7468F` - see
[HashiCorp's security page](https://www.hashicorp.com/trust/security)) before
trusting its checksums - a release with a missing or bad signature is
skipped rather than silently included. Takes about a minute for the full 1.x
history (~130 releases as of writing); only needs re-running when a new
Terraform version is released.

### OpenTofu and other forks

A `terraform.version` can point somewhere other than HashiCorp entirely, via
`url_template` (a string with literal `{version}`/`{platform}` placeholders,
substituted the same way for every platform) and `bin_name` (the executable's
name inside the archive, if not `terraform`/`terraform.exe`) - e.g.
[OpenTofu](https://github.com/opentofu/opentofu):

```starlark
terraform.version(
    version = "1.7.0",
    url_template = "https://github.com/opentofu/opentofu/releases/download/v{version}/tofu_{version}_{platform}.zip",
    bin_name = "tofu",
    sha256 = {
        "linux_amd64": "...",
        "linux_arm64": "...",
        "darwin_amd64": "...",
        "darwin_arm64": "...",
        "windows_amd64": "...",
    },
)
```

`sha256` is required here (not optional, unlike a plain HashiCorp version) -
the generated mirror above only covers HashiCorp's own archives, so it
doesn't apply once `url_template` overrides where the archive comes from.
Everything else (toolchain resolution, the `version` build setting,
`terraform_module`/`terraform_root`, the provider mirror, `registry_modules`)
works exactly the same either way; verified against a real OpenTofu 1.7.0
build (see `examples/opentofu`) - `cd examples && bazel run
//opentofu -- plan` genuinely fetches and runs `tofu`, not `terraform`.

## Supported platforms

`linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64`, `windows_amd64`
- see `_PLATFORMS` in `extensions.bzl` (no `windows_arm64`: HashiCorp doesn't
publish one). Each gets its own `@terraform_platform_<platform>` repository
(every requested Terraform version and provider, for that platform only);
the `@terraform` hub's `toolchain()`s just alias into whichever of these
Bazel's toolchain resolution actually needs. Since Bazel fetches external
repositories lazily, a given `bazel build`/`bazel run` invocation only ever
downloads the platform repo(s) matching its build graph's exec platform(s) -
typically just one - not all five.

## Windows

Every build action (staging, `init`/`validate`) and `terraform_root`'s
runtime wrapper are Python scripts, run via a hermetic Python interpreter
resolved from `rules_python`'s toolchain (see `bazel_dep(name =
"rules_python")` and the `python.toolchain(...)` call in this module's own
`MODULE.bazel`) - not bash, and not a Python assumed to already be on PATH.
This is what makes Windows support here better than "requires Git-Bash/MSYS2
on PATH": rules_python can fetch a Windows Python build the same way it
fetches one for Linux/macOS, so there's no extra manual setup expected on a
Windows machine beyond what any other rules_python-using Bazel module needs.

Two things are handled specially for Windows:

- The fetched Terraform/provider binaries are `.exe`s (`extensions.bzl`
  names the toolchain's `terraform_bin` `terraform.exe` there; the provider
  mirror doesn't care about exact filenames, so no change needed there).
- `terraform_root`'s `bazel run` executable can't be the `.py` script
  directly - Windows has no shebang-line support, so Bazel can't launch a
  text file with `#!/usr/bin/env python3` as a process (this is also why the
  build actions invoke the resolved interpreter directly as `executable =
  ...` rather than relying on a shebang at all). `windows_launcher` in
  `private/common.bzl` instead makes the executable a small `.bat` file that
  invokes the same resolved Python interpreter (found via its own runfiles
  path, not assumed to be on PATH) against the same script, setting
  `RUNFILES_DIR` explicitly first (Bazel names the runfiles directory after
  whichever file is `DefaultInfo.executable` - now the `.bat`, not the
  `.py` - so the `.py` script's own runfiles auto-detection would otherwise
  look in the wrong place).

The real, supported scenario is running Bazel *on* Windows directly (`bazel
build`/`bazel run` from a Windows machine, targeting Windows) - there, the
exec and target platforms are naturally both Windows and everything lines
up. Cross-compiling a Windows target from a different host isn't a
meaningful scenario for this module (`bazel run` always executes locally, on
whatever machine invoked it - there's no such thing as building for Windows
on Linux and later running it *there*), and isn't exercised beyond a
cross-compilation analysis smoke test (confirming the `.bat` launcher gets
generated without error) - it doesn't reflect real usage.

**Caveat**: this hasn't been tested on an actual Windows machine - I don't
have one available. The mechanism follows Bazel's own documented APIs
(`ctx.target_platform_has_constraint` for OS detection) and rules_python's
own toolchain-resolution APIs, and a cross-compiled analysis (`--platforms=<a
windows platform>`) confirms it generates without error, but real end-to-end
behavior is unverified. If something's off, `windows_launcher` in
`private/common.bzl` and the runner template's runfiles-detection logic
(`private/terraform_runner_template.py`) are the places to look first.

## Layout

- `toolchain.bzl` - `TerraformInfo`/`terraform_toolchain` (a Terraform
  binary) and `TerraformProviderMirrorInfo`/`terraform_provider_mirror_toolchain`
  (the provider filesystem mirror).
- `registry_module.bzl` - `TerraformRegistryModuleInfo`/`terraform_registry_module`
  (a pre-fetched third-party module).
- `testing.bzl` - `terraform_root_test`, see Testing above.
- `BUILD.bazel` - the two `toolchain_type`s and the `//:version` `string_flag`.
- `extensions.bzl` - the `terraform` module extension; generates the
  `@terraform` hub repo (`toolchain()`/`config_setting()` aliases per
  version/platform and per platform, plus third-party modules + one
  `terraform_registry_module` target each - not platform-specific, so fetched
  directly here) and, per platform, a `@terraform_platform_<platform>` repo
  (the real `terraform_toolchain` per version and `terraform_provider_mirror_toolchain`,
  lazily fetched only when that platform's toolchains are actually selected)
  from the `.version()`/`.provider()`/`.module()` tags - see
  `private/version.bzl`/`private/provider.bzl` for the per-tag-type logic. Also
  generates the hub's `//:default_script` (an `alias` to `.default_script()`'s
  `target`, or `private/default_terraform_script.py` if that tag wasn't
  declared) - see Custom workflows above.
- `defs.bzl` - the public API: just re-exports `terraform_module`/`terraform_root`/
  `terraform_local_provider` from `private/`. Nothing else should load this
  module's `.bzl` files directly other than `defs.bzl`, `extensions.bzl`, and
  `testing.bzl`.
  - `private/common.bzl` - `TerraformModuleInfo`, the shared attrs, the
    version transition, the hermetic Python toolchain helpers
    (`py_interpreter`/`py_runtime_files`), `windows_launcher`,
    `collect_provider_mirror_sources` (merges the toolchain-fetched mirror
    with any `local_providers`), and the staging/validate-action/manifest-
    generation logic both rules use.
  - `private/module.bzl` - `terraform_module`'s rule + implementation.
  - `private/root.bzl` - `terraform_root`'s rule + implementation.
  - `private/local_provider.bzl` - `TerraformLocalProviderInfo`/
    `terraform_local_provider` - see In-repo (local) providers above.
  - `private/stage_module.py` - the staging build action's script (copies
    transitive srcs + registry files into one tree), run via the resolved
    Python interpreter, not a shell.
  - `private/validate_module.py` - the `init && validate` build action's
    script, likewise run via the resolved Python interpreter - builds the
    provider mirror's `.terraformrc` and any pre-fab `modules.json` itself.
  - `private/terraform_runner_template.py` - template for `terraform_root`'s
    `bazel run`/`terraform_root_test` executable; expanded per-target via
    `ctx.actions.expand_template` (see `_terraform_root_impl`).
  - `private/terraform_root_test_template.py` - template for
    `terraform_root_test`'s executable (see `testing.bzl`); just locates
    `root`'s own executable via runfiles and execs it with `tf_args`.
  - `private/default_terraform_script.py` - `terraform_root`'s built-in
    default `script` (see Custom workflows above): auto-`init` then exec
    `terraform`, given `TF_BIN`/`TF_MODULE_DIR` in its environment (and
    `TF_MODULE_DIR` as its own cwd), same as any `script` would be.
  - `private/versions.bzl` - generated `TERRAFORM_VERSIONS` checksum mirror,
    see Checksum mirror above. Not loaded by `defs.bzl`/consumers directly -
    only `extensions.bzl` reads it.
- `scripts/mirror_terraform_versions.py` (+ its `BUILD.bazel`, a
  `py_binary`) - regenerates `private/versions.bzl`; see Checksum mirror
  above.
- `examples/` - `network` (a plain `terraform_module` pinned
  to 1.4.0, using the `hashicorp/random` provider *and* the third-party
  `cloudposse/label/null` registry module internally), `legacy` (a
  `terraform_root` on 1.4.0) and `new` (a `terraform_root` on 1.6.0) both
  depend on `network` with `dep_sources` wired, demonstrating a root and its
  dep pinned to different versions *and* a hermetic registry module nested
  through a local `deps` chain (manifest key `network.label`) - `thirdparty`
  (a `terraform_root` using the third-party `cloudposse/label/null` registry
  module directly), `opentofu` (a `terraform_root` on OpenTofu 1.7.0 via
  `url_template`/`bin_name`, not a HashiCorp Terraform build), and
  `cloudflare` (a `terraform_root` using the third-party `cloudflare/
  cloudflare` provider, fetched via `url_template`). `tests/` has the
  `analysistest` fixtures mentioned in Testing above, including
  `local_provider_layout_test` (`local_provider_test.bzl`), asserting a
  `terraform_local_provider` target lays its binary out at the expected
  filesystem-mirror path.

  This directory is its own separate Bazel module (own `MODULE.bazel`,
  module name `rules_terraform_examples`, listed in this directory's own
  `.bazelignore` so `rules_terraform`'s own build doesn't try to parse it) -
  consuming `rules_terraform` via `bazel_dep` + `local_path_override` the
  same way any other consumer would (see Usage above). It's also what
  `.bcr/terraform/presubmit.yml` runs against a released version, in the
  [VJftw/bazel-rules](https://github.com/VJftw/bazel-rules) monorepo this
  module lives in. Build/test it by `cd`ing in first: `cd examples && bazel
  test //...` - see Testing above.
