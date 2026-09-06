"""Shared implementation used by both `terraform_module` and `terraform_root`.

Not part of the public API - `//:defs.bzl` is. Kept here so the two rules
(`private/module.bzl`, `private/root.bzl`) share one copy of the provider,
attrs, transition, and staging/validate/manifest logic instead of drifting
apart.
"""

load("//:private/local_provider.bzl", "TerraformLocalProviderInfo")
load("//:registry_module.bzl", "TerraformRegistryModuleInfo")

TerraformModuleInfo = provider(
    doc = "A Terraform module: its own files plus the transitive files of any `deps` it local-sources.",
    fields = {
        "transitive_srcs": "depset[File]: this module's srcs plus every dep's, transitively.",
        "own_relpath": "String: this module's own directory, relative to any staged tree that includes its transitive_srcs (i.e. dirname of its own srcs[0]) - reusable by any consumer that also stages this module's files.",
        "manifest_entries": "list of struct(key=, kind=(\"local\"|\"registry\"), source=, version=, own_relpath=): every `.terraform/modules/modules.json` entry needed beneath this module's own root - see `collect_manifest_entries`.",
        "registry_files": "list of struct(key=, info=TerraformRegistryModuleInfo): every registry-kind entry's fetched files, for staging under `_registry_modules/<key>/` - see `collect_registry_files`.",
    },
)

TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))
PROVIDER_TOOLCHAIN_TYPE = str(Label("//:provider_toolchain_type"))
PY_TOOLCHAIN_TYPE = str(Label("@rules_python//python:toolchain_type"))
_VERSION_FLAG = str(Label("//:version"))

def py_interpreter(ctx):
    """Returns the hermetic Python interpreter `File` resolved via `PY_TOOLCHAIN_TYPE`.

    Every build action in this module that used to be a bash script (staging,
    validate) now runs as `ctx.actions.run(executable = py_interpreter(ctx),
    ...)` instead of `ctx.actions.run_shell(...)`, so it no longer depends on
    a shell being present on the exec platform.

    Args:
      ctx: the `terraform_module`/`terraform_root` rule context.

    Returns:
      The resolved `py3_runtime.interpreter` File.
    """
    return ctx.toolchains[PY_TOOLCHAIN_TYPE].py3_runtime.interpreter

def py_runtime_files(ctx):
    """Returns the depset of support files the resolved Python interpreter needs.

    Args:
      ctx: the `terraform_module`/`terraform_root` rule context.

    Returns:
      depset[File] - pass as (part of) a Python-invoking action's `inputs`.
    """
    return ctx.toolchains[PY_TOOLCHAIN_TYPE].py3_runtime.files

def windows_launcher(ctx, py_script, interpreter):
    """Wraps `py_script` in a native `.bat` launcher, if building for Windows.

    Bazel can't directly execute a shebang script there - `DefaultInfo.executable`
    needs an actual Windows-executable file (.exe/.bat/.cmd). Invokes the
    resolved (hermetic, rules_python-provided) Python interpreter rather than
    assuming one is installed on PATH - see the README's Windows section. Not
    needed on Linux/macOS, where the shebang script itself is directly
    executable (via its own `#!/usr/bin/env python3` line). Shared by
    `terraform_root` and `terraform_root_test` - both need a rule attr named
    `_windows_constraint` (default `@platforms//os:windows`) for this.

    Args:
      ctx: the rule context (`terraform_root` or `terraform_root_test`).
      py_script: the already-declared, already-written executable Python
        script `File`.
      interpreter: the resolved Python interpreter `File` (see
        `py_interpreter`), used only on Windows.

    Returns:
      The `File` that should be `DefaultInfo.executable` - `py_script`
      itself outside Windows, or a `.bat` sibling that invokes it via the
      resolved Python interpreter on Windows.
    """
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    if not is_windows:
        return py_script

    bat_script = ctx.actions.declare_file(ctx.label.name + "_runner.bat")

    # Bazel names the runfiles directory after whatever file is
    # DefaultInfo.executable - which is about to become THIS .bat file, not
    # py_script - so py_script's own runfiles-lookup boilerplate would look
    # in the wrong place. Set RUNFILES_DIR explicitly so it uses this
    # instead of guessing from its own (wrong, from this launcher) argv[0].
    ctx.actions.write(
        output = bat_script,
        is_executable = True,
        content = (
            "@echo off\r\n" +
            "set RUNFILES_DIR=%~dp0{bat_name}.runfiles\r\n" +
            "\"%RUNFILES_DIR%\\{interpreter_rlocation}\" \"%~dp0{py_name}\" %*\r\n"
        ).format(
            bat_name = bat_script.basename,
            interpreter_rlocation = rlocation_path(ctx, interpreter).replace("/", "\\"),
            py_name = py_script.basename,
        ),
    )
    return bat_script

def rlocation_path(ctx, file):
    # short_path is repo-relative; files from external repos get a "../repo/"
    # prefix instead of living under the main repo's own workspace name.
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return ctx.workspace_name + "/" + file.short_path

def _staging_relpath(file):
    # Like short_path, but without the "../repo/" external-repo prefix - a
    # clean relative path to use inside our own staging directory.
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]
    return file.short_path

def _dirname(path):
    return "/".join(path.split("/")[:-1])

def _provider_mirror_root(provider_files):
    # Every provider file lives under ".../providers/<hostname>/<namespace>/
    # <type>/<version>/<os_arch>/<binary>" (see extensions.bzl and
    # local_provider.bzl) - the mirror root is just the path up to and
    # including that "providers" directory. Assumes every file in
    # `provider_files` shares the same root, which holds both for the
    # toolchain-fetched mirror (one shared repo) and for a single
    # `terraform_local_provider` target's own files (its own dedicated
    # subtree) - see `collect_provider_mirror_sources`.
    for f in provider_files.to_list():
        idx = f.path.find("/providers/")
        if idx != -1:
            return f.path[:idx] + "/providers"
    return None

def collect_provider_mirror_sources(ctx, toolchain_provider_files):
    """Every independent provider-mirror source for this target: the toolchain's fetched mirror, plus any `local_providers`.

    Each source is kept separate (not merged into one depset) because each
    has its own mirror root directory - the toolchain-fetched mirror lives
    in its own per-platform repository, and each `terraform_local_provider`
    target lays its single provider out under its own dedicated output
    subtree (see `local_provider.bzl`). Terraform's CLI config supports
    multiple `filesystem_mirror` blocks, one per root, so there's no need to
    physically merge them - see `validate_action`/`terraform_runner_template.py`.

    Args:
      ctx: the `terraform_module`/`terraform_root` rule context.
      toolchain_provider_files: depset[File] from the resolved
        `PROVIDER_TOOLCHAIN_TYPE` toolchain.

    Returns:
      list[depset[File]] - one entry per independent mirror source.
    """
    sources = [toolchain_provider_files]
    for target in ctx.attr.local_providers:
        sources.append(target[TerraformLocalProviderInfo].files)
    return sources

def _flatten_direct_registry_module(key, info):
    """Expands a directly-declared `registry_modules` entry's vendor-nested chain.

    Recursively follows `info.nested` (declared via `terraform.module`'s
    `nested` attr) for further third-party modules it itself depends on.
    Returns a list of struct(key=, info=) - `info.nested` itself is never
    re-examined by a caller, since this already walks it fully.
    """
    result = [struct(key = key, info = info)]
    frontier = [(key, info)]

    # Starlark has no `while`; this bounds recursion depth generously (any
    # real vendor module-nesting chain is a handful of levels at most).
    for _ in range(20):
        if not frontier:
            break
        next_frontier = []
        for k, i in frontier:
            for nested_key, nested_info in i.nested.items():
                entry_key = k + "." + nested_key
                result.append(struct(key = entry_key, info = nested_info))
                next_frontier.append((entry_key, nested_info))
        frontier = next_frontier
    return result

def collect_registry_files(ctx):
    """(key, TerraformRegistryModuleInfo) pairs to stage under `_registry_modules/<key>/`.

    Covers this module's own `registry_modules` (expanded through any
    vendor-declared `nested` chains), plus every `deps` entry's own
    (already-expanded) registry files, re-prefixed by that dep's local call
    key - so a third-party module reachable through several levels of local
    `deps` still ends up staged, flat, under the outermost consumer's own
    tree.

    Args:
      ctx: the `terraform_module`/`terraform_root` rule context.

    Returns:
      list of struct(key=, info=TerraformRegistryModuleInfo).
    """
    infos = []
    for key, target in ctx.attr.registry_modules.items():
        infos.extend(_flatten_direct_registry_module(key, target[TerraformRegistryModuleInfo]))
    for dep_key, dep_target in ctx.attr.deps.items():
        for e in dep_target[TerraformModuleInfo].registry_files:
            infos.append(struct(key = dep_key + "." + e.key, info = e.info))
    return infos

def collect_manifest_entries(ctx):
    """Builds every `.terraform/modules/modules.json` entry this module needs.

    Covers this module's own root and what to hand up to whatever depends
    on this module as a `deps` entry.

    A `deps` entry only needs a manifest entry of its own if something
    hermetic (a `registry_modules`, at any depth) is reachable through it -
    Terraform resolves a plain local module for free either way, so those are
    left for it to discover itself. But when a `deps` entry DOES need an
    entry, Terraform must be told its EXACT `source = "..."` string (via
    `dep_sources`) - verified empirically: an exact-matching entry lets a
    nested registry entry beneath it survive `init` untouched, while a
    missing OR merely mismatched one makes Terraform re-discover that local
    module itself, silently wiping any pre-populated entries nested beneath
    it (even ones with otherwise-correct content).

    Args:
      ctx: the `terraform_module`/`terraform_root` rule context.

    Returns:
      list of struct(key=, kind=("local"|"registry"), source=, version=,
      own_relpath=).
    """
    entries = []
    for key, target in ctx.attr.registry_modules.items():
        for e in _flatten_direct_registry_module(key, target[TerraformRegistryModuleInfo]):
            entries.append(struct(key = e.key, kind = "registry", source = e.info.source, version = e.info.version, own_relpath = ""))

    for dep_key, dep_target in ctx.attr.deps.items():
        dep_info = dep_target[TerraformModuleInfo]
        if not dep_info.manifest_entries:
            continue
        if dep_key not in ctx.attr.dep_sources:
            fail((
                "{label}: dep \"{dep_key}\" has hermetic registry_modules " +
                "nested beneath it, so its exact `source = \"...\"` string " +
                "(as written in this target's own .tf `module \"{dep_key}\" " +
                "{{ ... }}` block) must be given via " +
                "`dep_sources = {{\"{dep_key}\": \"...\"}}`."
            ).format(label = ctx.label, dep_key = dep_key))
        entries.append(struct(
            key = dep_key,
            kind = "local",
            source = ctx.attr.dep_sources[dep_key],
            version = "",
            own_relpath = dep_info.own_relpath,
        ))
        for e in dep_info.manifest_entries:
            entries.append(struct(
                key = dep_key + "." + e.key,
                kind = e.kind,
                source = e.source,
                version = e.version,
                own_relpath = e.own_relpath,
            ))
    return entries

def _manifest_dict(manifest_entries, registry_root, staging_root):
    # A "registry"-kind entry points "Dir" at its staged files under
    # `registry_root/<key>` (see `stage_module`); a "local"-kind entry (a
    # `deps` ancestor needed to protect something nested beneath it - see
    # `collect_manifest_entries`) points "Dir" at `staging_root/<its
    # own_relpath>`, where its files already live via the normal
    # transitive_srcs staging. Verified empirically that a pre-populated
    # manifest with matching files already in place makes `terraform init`
    # skip the network entirely for all of it.
    entries = [{"Key": "", "Source": "", "Dir": "."}]
    for e in manifest_entries:
        entry = {"Key": e.key, "Source": e.source}
        if e.version:
            entry["Version"] = e.version
        if e.kind == "registry":
            entry["Dir"] = registry_root + "/" + e.key
        else:
            entry["Dir"] = staging_root + "/" + e.own_relpath
        entries.append(entry)
    return {"Modules": entries}

def build_manifest_json(manifest_entries, registry_root, staging_root):
    """Returns a `.terraform/modules/modules.json` document as a JSON string.

    Used when every path involved is already known at analysis time (i.e.
    `validate_action`'s build action) - `private/terraform_runner.py`
    recomputes the equivalent structure itself at runtime instead, since its
    paths (inside a `bazel run`-time scratch dir) aren't known until then.

    Args:
      manifest_entries: list from `collect_manifest_entries`.
      registry_root: path (relative to the action's cwd) under which
        `stage_module` staged every registry_files entry, keyed by `key`.
      staging_root: path (relative to the action's cwd) of the staged tree
        root - a "local"-kind entry's own_relpath is relative to this.

    Returns:
      A JSON string.
    """
    return json.encode(_manifest_dict(manifest_entries, registry_root, staging_root))

def manifest_entries_to_json(manifest_entries):
    """Serializes `manifest_entries` to a plain JSON list, for embedding in a runtime script.

    Args:
      manifest_entries: list from `collect_manifest_entries`.

    Returns:
      A JSON string: a list of {key, kind, source, version, own_relpath} objects.
    """
    return json.encode([
        {"key": e.key, "kind": e.kind, "source": e.source, "version": e.version, "own_relpath": e.own_relpath}
        for e in manifest_entries
    ])

def _version_transition_impl(_settings, attr):
    return {_VERSION_FLAG: attr.version}

# An outgoing (self) transition: it changes the configuration a target itself
# builds under, based on that target's own `version` attribute. This is what
# lets a `legacy` root pinned to "1.4.0" and a `new` root pinned to "1.6.0"
# resolve to different Terraform toolchains within the very same build - and,
# since `terraform_module` applies the same transition, a module can pin its
# own version too, independent of whatever `terraform_root` depends on it.
VERSION_TRANSITION = transition(
    implementation = _version_transition_impl,
    inputs = [],
    outputs = [_VERSION_FLAG],
)

COMMON_ATTRS = {
    "srcs": attr.label_list(
        allow_files = True,
        mandatory = True,
        doc = "This module's own files. srcs[0] must be a file directly inside the module's directory (e.g. its main.tf).",
    ),
    "deps": attr.string_keyed_label_dict(
        providers = [TerraformModuleInfo],
        doc = "Other `terraform_module` targets this module references via local (relative-path) `source = ...` module blocks, keyed by the local module call name - e.g. `{\"network\": \"//path:network\"}` for a `module \"network\" { source = \"../network\" }` block. If that dep has any `registry_modules` (or its own nested `deps`) beneath it, this target must also set `dep_sources` for it.",
    ),
    "dep_sources": attr.string_dict(
        doc = "Exact `source = \"...\"` string as written in this target's own .tf, for each `deps` entry that has hermetic `registry_modules` nested beneath it - e.g. `{\"network\": \"../network\"}`. Only required for such deps (Terraform's manifest needs it to match exactly, or it re-discovers - and un-hermetically re-fetches - everything beneath that dep); a plain local dep with nothing hermetic beneath it needs no entry here.",
    ),
    "registry_modules": attr.string_keyed_label_dict(
        providers = [TerraformRegistryModuleInfo],
        doc = "Third-party (registry/git) modules referenced by this module's own `.tf` files, keyed by the local module call name - e.g. `{\"vpc\": \"@terraform//:module_vpc\"}` for a `module \"vpc\" { source = ... }` block. Values are `terraform_registry_module` targets from the `terraform` module extension's `.module()` tag. Only covers module calls written directly in this target's own `srcs` - a third-party module referenced from within a `deps` module needs its own `registry_modules` wiring on that target instead (it'll be picked up automatically via `deps`/`dep_sources`). A third-party module that itself depends on further third-party modules the extension can't discover on its own is covered by that module's own `terraform.module` `nested` tag attribute, not by this attribute.",
    ),
    "local_providers": attr.label_list(
        providers = [TerraformLocalProviderInfo],
        doc = "In-repo-built Terraform provider plugins (`terraform_local_provider` targets - see local_provider.bzl) to add to the offline provider mirror this target's `init`/`validate`/`plan`/etc use, alongside whatever the `terraform` module extension's `.provider()` tags fetched. Lets a `required_providers` entry resolve to a provider built as part of this same build (e.g. a `go_binary`) instead of a published release.",
    ),
    "version": attr.string(
        mandatory = True,
        doc = "Terraform version to run/validate this module against, e.g. '1.4.0'. Must be registered via the `terraform` module extension. Independent of any `terraform_root` that depends on this module - they don't need to match.",
    ),
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
    "_stage_module_py": attr.label(default = "//:private/stage_module.py", allow_single_file = True),
    "_validate_module_py": attr.label(default = "//:private/validate_module.py", allow_single_file = True),
}

def collect_transitive_srcs(ctx):
    return depset(
        direct = ctx.files.srcs,
        transitive = [dep[TerraformModuleInfo].transitive_srcs for dep in ctx.attr.deps.values()],
    )

def stage_module(ctx, transitive_srcs, registry_files):
    """Copies every transitive src, plus every registry file, into one tree artifact.

    Preserves each file's relative path (so local `source = "../foo"` module
    references still resolve). Terraform only ever runs against this
    Bazel-owned copy - never the real source directory - so it works the
    same whether a file is a checked-in source or something a future rule
    generates, and `init`/`plan`/etc never write `.terraform/`, state, or
    lock files back into the source tree.

    Each `registry_files` entry is staged under
    `<module_relpath>/_registry_modules/<key>/` - `build_manifest_json`/
    `manifest_entries_to_json` then point a pre-fabricated `.terraform/
    modules/modules.json` at that path, so `init` never has to fetch it.

    Args:
      ctx: the `terraform_module`/`terraform_root` rule context.
      transitive_srcs: depset[File] from `collect_transitive_srcs`.
      registry_files: list from `collect_registry_files`.

    Returns:
      (staging_dir, module_relpath): the declared tree artifact `File`, and
      this module's own directory relative to it.
    """
    staging_dir = ctx.actions.declare_directory(ctx.label.name + "_module")
    module_relpath = _dirname(_staging_relpath(ctx.files.srcs[0]))

    pairs = []
    for f in transitive_srcs.to_list():
        pairs.append([f.path, _staging_relpath(f)])

    for e in registry_files:
        info = e.info
        marker = info.root + "/"
        for f in info.files.to_list():
            rel = _staging_relpath(f)
            inner = rel[rel.find(marker) + len(marker):]
            pairs.append([f.path, "{}/_registry_modules/{}/{}".format(module_relpath, e.key, inner)])

    manifest = ctx.actions.declare_file(ctx.label.name + "_stage_manifest.json")
    ctx.actions.write(output = manifest, content = json.encode(pairs))

    ctx.actions.run(
        outputs = [staging_dir],
        inputs = depset(
            [manifest],
            transitive = [transitive_srcs, py_runtime_files(ctx)] + [e.info.files for e in registry_files],
        ),
        executable = py_interpreter(ctx),
        tools = [ctx.file._stage_module_py],
        arguments = [ctx.file._stage_module_py.path, "--manifest", manifest.path, "--out", staging_dir.path],
        mnemonic = "TerraformStageModule",
        progress_message = "Staging Terraform module %s" % ctx.label,
    )

    return staging_dir, module_relpath

def validate_action(ctx, staging_dir, module_relpath, terraform_bin, provider_mirror_sources, manifest_entries):
    """Registers the build-time `terraform init && terraform validate` action.

    Args:
      ctx: the `terraform_module`/`terraform_root` rule context.
      staging_dir: tree artifact from `stage_module`.
      module_relpath: this module's own directory, from `stage_module`.
      terraform_bin: the resolved `TerraformInfo.terraform_bin` executable.
      provider_mirror_sources: list[depset[File]] from
        `collect_provider_mirror_sources` - one independent mirror root's
        worth of files per entry.
      manifest_entries: list from `collect_manifest_entries`.

    Returns:
      The declared `.validated` marker `File`.
    """
    inputs = [staging_dir]
    transitive_inputs = [py_runtime_files(ctx)]
    extra_args = []

    for provider_files in provider_mirror_sources:
        mirror_root = _provider_mirror_root(provider_files)
        if mirror_root != None:
            # `mirror_root` is only known here as an execroot-relative path,
            # and the action absolute-ifies it itself (see
            # validate_module.py) - a relative path baked into the CLI
            # config file's content wouldn't survive Terraform's own
            # `-chdir` (which changes the process's cwd before anything
            # reads the config's provider mirror `path`).
            transitive_inputs.append(provider_files)
            extra_args += ["--provider-mirror-root", mirror_root]

    if manifest_entries:
        manifest_seed = ctx.actions.declare_file(ctx.label.name + "_modules_seed.json")
        ctx.actions.write(
            output = manifest_seed,
            content = build_manifest_json(
                manifest_entries = manifest_entries,
                registry_root = staging_dir.path + "/" + module_relpath + "/_registry_modules",
                staging_root = staging_dir.path,
            ),
        )
        inputs.append(manifest_seed)
        extra_args += ["--manifest-seed", manifest_seed.path]

    # `staging_dir` is a build output, so Bazel has made it read-only. Rather
    # than copy it somewhere writable (which risks stale files left behind if
    # a `.tf` file gets renamed - Bazel always rebuilds `staging_dir`
    # correctly, but a naive copy of it wouldn't be resynced the same way),
    # point `-chdir` straight at it and only let TF_DATA_DIR (a plain scratch
    # dir the action creates itself - see validate_module.py) be writable.
    marker = ctx.actions.declare_file(ctx.label.name + ".validated")

    ctx.actions.run(
        outputs = [marker],
        inputs = depset(inputs, transitive = transitive_inputs),
        executable = py_interpreter(ctx),
        tools = [terraform_bin, ctx.file._validate_module_py],
        arguments = [
            ctx.file._validate_module_py.path,
            "--terraform-bin",
            terraform_bin.path,
            "--module-dir",
            staging_dir.path + "/" + module_relpath,
            "--marker",
            marker.path,
        ] + extra_args,
        mnemonic = "TerraformValidate",
        progress_message = "Validating Terraform module %s" % ctx.label,
    )
    return marker
