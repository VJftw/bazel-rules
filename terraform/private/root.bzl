"""`terraform_root`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("@rules_nushell//:nu.bzl", "NU_LAUNCHER_ATTRS", "nu_launcher")
load(
    "//:private/common.bzl",
    "COMMON_ATTRS",
    "NU_TOOLCHAIN_TYPE",
    "PROVIDER_TOOLCHAIN_TYPE",
    "TOOLCHAIN_TYPE",
    "TerraformModuleInfo",
    "VERSION_TRANSITION",
    "collect_manifest_entries",
    "collect_provider_mirror_sources",
    "collect_registry_files",
    "collect_transitive_srcs",
    "manifest_entries_to_json",
    "rlocation_path",
    "stage_module",
    "validate_action",
)

_RUNNER_TEMPLATE = Label("//:private/terraform_runner_template.nu")

# What `bazel run`/`bazel test` (terraform_root_test) hands off to, always -
# an `alias` to whatever `terraform.default_script(target = ...)` requested
# (see extensions.bzl), or (if no such tag was declared) this module's own
# built-in auto-init-then-`terraform` script. Not a `terraform_root` attr -
# every target in the build uses whichever one this resolves to; there's no
# per-target override. Resolved from *this* module's own repo mapping (like
# any `Label()` literal in a .bzl file), not a consumer's - which is why this
# module's own MODULE.bazel `use_repo`s its own `terraform` extension's hub,
# so "@terraform" here always means the one, singleton hub shared by the
# whole build.
_SCRIPT = Label("@terraform//:default_script")

# Set by the runner itself (TF_BIN/TF_MODULE_DIR/TF_LABEL/TF_ROOT_NAME/
# TF_ROOT_PACKAGE/TF_VERSION always; TF_CLI_CONFIG_FILE only when a provider
# mirror is in play) - always take precedence over `env`/`env_labels` there,
# so a target declaring one of these here would be silently shadowed at
# runtime. Caught here instead, with a clear error, rather than left as a
# runtime surprise.
_RESERVED_ENV_NAMES = ["TF_BIN", "TF_MODULE_DIR", "TF_CLI_CONFIG_FILE", "TF_LABEL", "TF_ROOT_NAME", "TF_ROOT_PACKAGE", "TF_VERSION"]

def _resolve_env_labels(ctx):
    """Resolves `ctx.attr.env_labels` to {var name: rlocation path}, plus the files/runfiles those need.

    Args:
      ctx: the `terraform_root` rule context.

    Returns:
      (dict[str, str], list[File], list[runfiles]): rlocation paths keyed by
      env var name; the resolved output `File` for each entry; and each
      label's own default runfiles - both lists for the caller to fold into
      the runner's own runfiles.
    """
    paths = {}
    files_out = []
    extra_runfiles = []
    for var_name, target in ctx.attr.env_labels.items():
        if var_name in _RESERVED_ENV_NAMES:
            fail("{label}: env_labels[\"{var}\"]: \"{var}\" is set by the runner itself and can't be overridden.".format(label = ctx.label, var = var_name))
        if var_name in ctx.attr.env:
            fail("{label}: \"{var}\" is set in both `env` and `env_labels` - remove it from one.".format(label = ctx.label, var = var_name))
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail((
                "{label}: env_labels[\"{var}\"] = {dep} produces {n} files, " +
                "but exactly one is required so \"${var}\" can resolve to a " +
                "single path - point it at a target with one output instead."
            ).format(label = ctx.label, var = var_name, dep = target.label, n = len(files)))
        paths[var_name] = rlocation_path(ctx, files[0])
        files_out.append(files[0])
        extra_runfiles.append(target[DefaultInfo].default_runfiles)
    return paths, files_out, extra_runfiles

def _resolve_script(ctx):
    """Resolves `ctx.attr._script` (see `_SCRIPT` above) to its rlocation path, plus the files/runfiles it needs.

    Accepts two shapes of target: an executable rule (`nu_binary`,
    `sh_binary`, etc. - anything with `executable = True`), identified via
    `files_to_run.executable` (the queryable accessor for what a rule
    constructed `DefaultInfo(executable = ...)` with - that field itself
    isn't readable back off a fetched `DefaultInfo`) regardless of how many
    other files its `DefaultInfo.files` bundles alongside it (e.g.
    `sh_binary` always also exposes its own source script there); or a
    plain, single-file target (a checked-in script with its executable bit
    set) with no such executable, which must resolve to exactly one file
    since there'd otherwise be no single file to mean.

    Args:
      ctx: the `terraform_root` rule context.

    Returns:
      (str, list[File], list[runfiles]): the resolved executable `File`'s
      rlocation path, every file the target exposes via `DefaultInfo.files`
      (so any extra files an executable rule bundles alongside its
      executable, e.g. `sh_binary`'s own source script, still land in
      runfiles), and the label's own default runfiles (as a single-element
      list) - both lists for the caller to fold into the runner's own
      runfiles.
    """
    target = ctx.attr._script
    files = target[DefaultInfo].files.to_list()
    executable = target.files_to_run.executable
    if executable == None:
        if len(files) != 1:
            fail((
                "terraform.default_script(target = {dep}) produces {n} files " +
                "and isn't executable - point it at an executable target " +
                "(e.g. nu_binary, sh_binary) or one with a single output " +
                "instead."
            ).format(dep = target.label, n = len(files)))
        executable = files[0]
    return rlocation_path(ctx, executable), files, [target[DefaultInfo].default_runfiles]

def _terraform_root_impl(ctx):
    toolchain_info = ctx.toolchains[TOOLCHAIN_TYPE].terraform_info
    terraform_bin = toolchain_info.terraform_bin
    toolchain_provider_files = ctx.toolchains[PROVIDER_TOOLCHAIN_TYPE].provider_mirror_info.files
    provider_mirror_sources = collect_provider_mirror_sources(ctx, toolchain_provider_files)

    if toolchain_info.version != ctx.attr.version:
        fail((
            "terraform_root {name} requested version {want}, but resolved " +
            "toolchain is version {got}. Is that version registered via the " +
            "`terraform` module extension?"
        ).format(name = ctx.label, want = ctx.attr.version, got = toolchain_info.version))

    for var_name in ctx.attr.env:
        if var_name in _RESERVED_ENV_NAMES:
            fail("{label}: env[\"{var}\"]: \"{var}\" is set by the runner itself and can't be overridden.".format(label = ctx.label, var = var_name))
    env_label_paths, env_label_files, env_label_runfiles = _resolve_env_labels(ctx)
    script_rlocation, script_files, script_runfiles = _resolve_script(ctx)

    transitive_srcs = collect_transitive_srcs(ctx)
    registry_files = collect_registry_files(ctx)
    manifest_entries = collect_manifest_entries(ctx)
    staging_dir, module_relpath = stage_module(ctx, transitive_srcs, registry_files)
    marker = validate_action(ctx, staging_dir, module_relpath, terraform_bin, provider_mirror_sources, manifest_entries)

    # One representative file per independent mirror source (see
    # `collect_provider_mirror_sources`) - the runner reconstructs each
    # source's own mirror root from its representative file's rlocation path
    # at runtime (rlocation paths, unlike build-time paths, aren't known
    # until then) - see `terraform_runner_template.nu`.
    provider_repr_rlocations = []
    for files in provider_mirror_sources:
        files_list = files.to_list()
        if files_list:
            provider_repr_rlocations.append(rlocation_path(ctx, files_list[0]))

    manifest_file = ctx.actions.declare_file(ctx.label.name + "_runner_manifest.json")
    ctx.actions.write(output = manifest_file, content = manifest_entries_to_json(manifest_entries))

    script = ctx.actions.declare_file(ctx.label.name + "_runner.nu")
    ctx.actions.expand_template(
        template = ctx.file._runner_template,
        output = script,
        substitutions = {
            "%{tf_rlocation}%": rlocation_path(ctx, terraform_bin),
            "%{provider_repr_rlocations_json}%": json.encode(provider_repr_rlocations),
            "%{staging_rlocation}%": rlocation_path(ctx, staging_dir),
            "%{manifest_rlocation}%": rlocation_path(ctx, manifest_file),
            "%{module_relpath}%": module_relpath,
            "%{label_key}%": (ctx.label.package + "/" + ctx.label.name).replace("/", "_"),
            # `str(ctx.label)` renders bzlmod's full canonical form (e.g.
            # "@@//legacy:legacy" for the main repo) - this instead matches
            # what a user would actually type ("//legacy:legacy", or
            # "@repo//pkg:name" for an external one).
            "%{tf_label}%": ("@" + ctx.label.repo_name if ctx.label.repo_name else "") + "//" + ctx.label.package + ":" + ctx.label.name,
            "%{tf_root_name}%": ctx.label.name,
            "%{tf_root_package}%": ctx.label.package,
            "%{tf_version}%": ctx.attr.version,
            "%{env_json}%": json.encode(ctx.attr.env),
            "%{env_labels_json}%": json.encode(env_label_paths),
            "%{script_rlocation}%": script_rlocation,
        },
    )

    launcher = nu_launcher(ctx, script)
    executable = launcher.executable

    runfiles = ctx.runfiles(files = [terraform_bin, staging_dir, manifest_file] + env_label_files + script_files)
    runfiles = runfiles.merge_all([launcher.runfiles] + [
        ctx.runfiles(transitive_files = files)
        for files in provider_mirror_sources
    ] + env_label_runfiles + script_runfiles)

    return [
        TerraformModuleInfo(
            transitive_srcs = transitive_srcs,
            own_relpath = module_relpath,
            manifest_entries = manifest_entries,
            registry_files = registry_files,
        ),
        DefaultInfo(executable = executable, runfiles = runfiles, files = depset([marker, executable, staging_dir])),
    ]

terraform_root = rule(
    implementation = _terraform_root_impl,
    executable = True,
    cfg = VERSION_TRANSITION,
    doc = """A `terraform_module` that is also a Root Terraform Module: pinned to a
    specific Terraform `version`, and executable so you can `bazel run` it to
    `plan`, `apply`, etc, e.g. `bazel run //path/to:legacy -- plan`.

    Building it (as with a plain `terraform_module`) runs `terraform init &&
    terraform validate` against its own files and its `deps`' files, using
    its own pinned `version` (a `terraform_module` dep may pin a different
    `version` for itself - see `terraform_module`'s doc). Both the
    build-time validation and any `bazel run ... -- plan/apply` use the
    offline provider mirror, same as `terraform_module`, and both copy the
    staged module tree into a scratch directory inside Bazel's own execroot
    (not /tmp, not the source tree) rather than running against the real
    source directory or the (read-only) staged tree directly.

    That scratch dir is rebuilt by Bazel on every build/run, so it doesn't
    persist across separate `bazel run` invocations - to compensate, `bazel
    run ... -- plan` (or `apply`, `destroy`, `validate`, `refresh`,
    `import`, `console`, `output`) automatically runs `init` first, so you
    don't have to remember to.

    `bazel run //path:name -- args...` always hands off to a script, once
    staging/the provider mirror/manifest fabrication above are all set up -
    this module's own built-in one (auto-`init` before `plan`/`apply`/etc,
    then exec `terraform` itself, i.e. the behavior described above) unless
    `terraform.default_script(target = ...)` (a `terraform` module extension
    tag - see `extensions.bzl`) names a different one for the whole build,
    e.g. for a custom workflow (an approval gate, a notification, wrapping
    several terraform invocations) that this rule doesn't otherwise support.
    That script gets `TF_BIN` (the resolved terraform binary) and
    `TF_MODULE_DIR` (the writable, already-initialized-if-you-init-it module
    dir) in its environment, plus `args...` as its own argv - it also runs
    with `TF_MODULE_DIR` as its current working directory already, and a
    `PATH` prepended with an entry named after whatever `TF_BIN` actually
    resolved to (`terraform`, or `tofu`/whatever else a non-default
    `bin_name` chose), so plain `terraform args...` (no `$TF_BIN`, no
    `-chdir=...`) works directly, same as it would in a real shell. A custom
    one is responsible for invoking terraform itself; no auto-`init` happens
    for it. It also gets `TF_LABEL` (this target's own
    canonical label, e.g. `//path/to:name`), `TF_ROOT_NAME`/`TF_ROOT_PACKAGE`
    (that label's name/package separately), and `TF_VERSION` (its pinned
    Terraform `version`) - metadata a workspace-wide script (see
    `terraform.default_script` above) can use to identify which
    `terraform_root` it's running for, e.g. to scope state or tag a
    notification. This target's own `env`/`env_labels` attrs (see below) are
    set in its environment too.

    Runs as a Nushell script, via rules_nushell's hermetic,
    toolchain-resolved `nu` (not bash, or whatever else is on the machine):
    `bazel run`'s executable is a tiny generated launcher for it - a
    `/bin/sh` script, or a `.bat` on Windows (see the README's Windows
    section); everything else is identical.
    """,
    attrs = dict(
        COMMON_ATTRS,
        env = attr.string_dict(
            doc = "Static environment variables set on this target's `bazel run`/`bazel test` (terraform_root_test) invocation, whichever script it hands off to (see above). Takes precedence over whatever's already in the invoking shell's environment (so it's for fixed config this target needs, e.g. `TF_LOG`, `AWS_PROFILE` - not a default callers should be able to override per-invocation via their own shell env). Only affects the runtime `bazel run` wrapper, not the build-time `init && validate` action. A name also used in `env_labels`, or one of the runner's own reserved names (`TF_BIN`, `TF_MODULE_DIR`, `TF_CLI_CONFIG_FILE`, `TF_LABEL`, `TF_ROOT_NAME`, `TF_ROOT_PACKAGE`, `TF_VERSION`), is a build error.",
        ),
        env_labels = attr.string_keyed_label_dict(
            allow_files = True,
            doc = "Like `env`, but each value is a label instead of a literal string - e.g. `{\"TOOL\": \"//tools:mytool\"}` makes `$TOOL` the absolute runtime path to `//tools:mytool`'s built output, for a `terraform.default_script`-declared workflow to use. The label must resolve to exactly one file (`DefaultInfo.files`); anything with more than one (e.g. a multi-output `filegroup`) is a build error, since there'd be no single path for the variable to mean. Automatically added to this target's runfiles - no separate `data` wiring needed. Same reserved-name and `env`-overlap restrictions as `env`.",
        ),
        _runner_template = attr.label(default = _RUNNER_TEMPLATE, allow_single_file = True),
        _script = attr.label(allow_files = True, default = _SCRIPT),
        **NU_LAUNCHER_ATTRS
    ),
    toolchains = [TOOLCHAIN_TYPE, PROVIDER_TOOLCHAIN_TYPE, NU_TOOLCHAIN_TYPE],
)
