#!/usr/bin/env python3
"""Template for a `terraform_root`'s `bazel run`/`terraform_root_test` executable.

Expanded (via `ctx.actions.expand_template`, substituting the `%{...}%`
tokens below) into a real, per-target executable by `private/root.bzl` - see
`_terraform_root_impl`. Not a build action's helper script (unlike
private/stage_module.py and private/validate_module.py, invoked directly via
the hermetic Python toolchain) - this one becomes `DefaultInfo.executable`
itself, so on Unix it's directly executed via its own `#!/usr/bin/env
python3` shebang above (the same default Python rules use for their own
launcher stub - true build-time hermeticity comes from the resolved
toolchain interpreter used for the build actions, not this launch step); on
Windows, a tiny generated `.bat` (see `_windows_launcher`) invokes the
resolved toolchain's `python.exe` with this file instead.

Runs as a plain script (no `bazel_tools`/`rules_python` runfiles library
dependency, to avoid the sys.path/import wiring a non-`py_binary` executable
would need for that) - `_rlocation` below reimplements just enough runfiles
lookup itself.

Always hands `bazel run //path:name -- args...` off to another script (see
SCRIPT_RLOCATION in `main`) once staging/the provider mirror/manifest
fabrication are set up - private/default_terraform_script.py (this module's
built-in auto-init-then-`terraform` one) unless `root.bzl`'s `_SCRIPT`
resolved to something else (a `terraform.default_script(target = ...)`
request - see extensions.bzl).
"""
import json
import os
import shutil
import sys

TF_RLOCATION = "%{tf_rlocation}%"
PROVIDER_REPR_RLOCATIONS = json.loads("""%{provider_repr_rlocations_json}%""")
STAGING_BASENAME = "%{staging_basename}%"
MANIFEST_BASENAME = "%{manifest_basename}%"
MODULE_RELPATH = "%{module_relpath}%"
LABEL_KEY = "%{label_key}%"
TF_LABEL = "%{tf_label}%"
TF_ROOT_NAME = "%{tf_root_name}%"
TF_ROOT_PACKAGE = "%{tf_root_package}%"
TF_VERSION = "%{tf_version}%"
EXTRA_ENV = json.loads("""%{env_json}%""")
ENV_LABEL_RLOCATIONS = json.loads("""%{env_labels_json}%""")
SCRIPT_RLOCATION = "%{script_rlocation}%"

FILESYSTEM_MIRROR_BLOCK = """
  filesystem_mirror {
    path    = "%s"
    include = ["*/*/*"]
  }"""

# See the matching comment in validate_module.py - one block per independent
# mirror root, `direct` excluded unconditionally so an unmirrored provider
# fails loudly instead of silently trying the network.
PROVIDER_CLI_CONFIG = """
disable_checkpoint = true

provider_installation {
%s
  direct {
    exclude = ["*/*/*"]
  }
}
"""


def _rlocation(path):
    """Resolves a runfiles-root-relative path to a real filesystem path.

    Bazel always sets RUNFILES_DIR or RUNFILES_MANIFEST_FILE when invoking an
    executable via `bazel run`/`bazel test`; the sys.argv[0]-relative
    fallbacks below cover directly executing the built script instead.
    """
    script = os.path.abspath(sys.argv[0])

    manifest = os.environ.get("RUNFILES_MANIFEST_FILE")
    if not manifest:
        for candidate in (script + ".runfiles_manifest", script + ".runfiles/MANIFEST"):
            if os.path.exists(candidate):
                manifest = candidate
                break

    if manifest:
        with open(manifest, encoding="utf-8") as f:
            for line in f:
                link, _, target = line.rstrip("\n").partition(" ")
                if link == path:
                    return target
        sys.exit("ERROR: %s not found in runfiles manifest %s" % (path, manifest))

    runfiles_dir = os.environ.get("RUNFILES_DIR")
    if not runfiles_dir and os.path.isdir(script + ".runfiles"):
        runfiles_dir = script + ".runfiles"
    if runfiles_dir:
        return os.path.join(runfiles_dir, path)

    sys.exit("ERROR: cannot find runfiles (no RUNFILES_DIR/RUNFILES_MANIFEST_FILE, run via `bazel run`/`bazel test`)")


def _build_manifest(entries, registry_root, staging_root):
    modules = [{"Key": "", "Source": "", "Dir": "."}]
    for e in entries:
        entry = {"Key": e["key"], "Source": e["source"]}
        if e["version"]:
            entry["Version"] = e["version"]
        if e["kind"] == "registry":
            entry["Dir"] = registry_root + "/" + e["key"]
        else:
            entry["Dir"] = staging_root + "/" + e["own_relpath"]
        modules.append(entry)
    return {"Modules": modules}


def _bin_dir(scratch, tf_bin):
    """Creates `scratch`'s `bin/` dir, with an entry that runs `tf_bin` under its own basename.

    e.g. `tf_bin` resolving to a `bin_name = "tofu"` build makes `bin/tofu`
    (or `bin/tofu.bat` on Windows, since PATH-based lookup there doesn't need
    the extension typed) - so a script can `PATH`-prepend the returned
    directory and just run `tofu` (or `terraform`, whatever this target's
    `version`/`bin_name` actually resolved to) instead of needing `$TF_BIN`.

    Args:
      scratch: this target's writable, execroot-scoped scratch dir (rebuilt
        every run, so any conflicting name in `bin_name` here is impossible).
      tf_bin: the resolved terraform (or tofu, ...) binary's real path.

    Returns:
      The created `bin/` directory's path.
    """
    bin_dir = os.path.join(scratch, "bin")
    os.makedirs(bin_dir, exist_ok = True)
    bin_name = os.path.splitext(os.path.basename(tf_bin))[0]

    if os.name == "nt":
        # No unprivileged symlinks on Windows - a tiny generated wrapper
        # instead. `%*`/`%ERRORLEVEL%` forward args and exit code straight
        # through, so it's transparent to the caller either way.
        with open(os.path.join(bin_dir, bin_name + ".bat"), "w", encoding = "utf-8") as f:
            f.write("@echo off\r\n\"{tf_bin}\" %*\r\nexit /b %ERRORLEVEL%\r\n".format(tf_bin = tf_bin))
    else:
        os.symlink(tf_bin, os.path.join(bin_dir, bin_name))

    return bin_dir


def _make_writable(path):
    # `staged` (below) is a build output, so Bazel made its copy read-only;
    # `cp -r`'s bash equivalent inherited that too (umask can only remove
    # bits, not add), so this was needed there as well.
    for dirpath, dirnames, filenames in os.walk(path):
        for name in dirnames + filenames:
            p = os.path.join(dirpath, name)
            os.chmod(p, os.stat(p).st_mode | 0o200)
    os.chmod(path, os.stat(path).st_mode | 0o200)


def main():
    script_dir = os.path.dirname(os.path.abspath(sys.argv[0]))
    tf_bin = _rlocation(TF_RLOCATION)

    # STAGING_BASENAME/MANIFEST_BASENAME are declared outputs in this same
    # package/configuration as this script, so they're always siblings of
    # it - no runfiles lookup needed.
    staged = os.path.join(script_dir, STAGING_BASENAME)

    # `staged` is read-only and `init`/`plan`/`apply` need to write into the
    # module dir (.terraform/, state, lock file) - copy into a scratch dir
    # kept inside Bazel's own execroot (a sibling of "bazel-out", not /tmp or
    # the real source tree), so `bazel clean` removes it like any other
    # build artifact. Bazel rebuilds execroot's contents on every build/run,
    # so this scratch dir doesn't survive between separate `bazel run`
    # invocations - to compensate, `init` is re-run automatically below
    # before any subcommand that needs it.
    execroot_workspace = script_dir.split(os.sep + "bazel-out" + os.sep)[0]
    scratch = os.path.join(execroot_workspace, "rules_terraform_scratch", LABEL_KEY)
    if os.path.exists(scratch):
        shutil.rmtree(scratch)
    shutil.copytree(staged, scratch)
    _make_writable(scratch)

    module_dir = os.path.join(scratch, MODULE_RELPATH)
    env = dict(os.environ)
    # Target-declared `env`/`env_labels` (terraform_root's attrs of the same
    # names) always win over whatever the invoking shell already set - meant
    # as fixed config for this target (e.g. TF_LOG, AWS_PROFILE, or a tool's
    # resolved path), not a per-invocation default a caller should be able
    # to shadow. TF_BIN/TF_MODULE_DIR/TF_CLI_CONFIG_FILE below are set after
    # this and always win over both in turn, since those are structural, not
    # user config (root.bzl rejects an `env`/`env_labels` entry using one of
    # those names at analysis time, rather than letting it be silently
    # shadowed here).
    env.update(EXTRA_ENV)
    env.update({name: _rlocation(rloc) for name, rloc in ENV_LABEL_RLOCATIONS.items()})

    if PROVIDER_REPR_RLOCATIONS:
        mirror_roots = []
        for repr_rlocation in PROVIDER_REPR_RLOCATIONS:
            provider_repr = _rlocation(repr_rlocation)
            mirror_roots.append(provider_repr.split(os.sep + "providers" + os.sep)[0] + os.sep + "providers")
        blocks = "\n".join(FILESYSTEM_MIRROR_BLOCK % root for root in mirror_roots)
        cli_config_path = os.path.join(scratch, ".terraformrc")
        with open(cli_config_path, "w", encoding="utf-8") as f:
            f.write(PROVIDER_CLI_CONFIG % blocks)
        env["TF_CLI_CONFIG_FILE"] = cli_config_path

    with open(os.path.join(script_dir, MANIFEST_BASENAME), encoding="utf-8") as f:
        manifest_entries = json.load(f)
    if manifest_entries:
        registry_root = os.path.join(scratch, MODULE_RELPATH, "_registry_modules")
        modules_dir = os.path.join(module_dir, ".terraform", "modules")
        os.makedirs(modules_dir, exist_ok=True)
        with open(os.path.join(modules_dir, "modules.json"), "w", encoding="utf-8") as f:
            json.dump(_build_manifest(manifest_entries, registry_root, scratch), f)

    args = sys.argv[1:]

    # Hand off to whichever script `root.bzl` resolved `_SCRIPT` to - this
    # module's own built-in one by default, or a `terraform.default_script`
    # request - with the same hermetic module dir/binary/provider config this
    # runner itself used to set up, and let it drive terraform (or anything
    # else) however it wants.
    script_path = _rlocation(SCRIPT_RLOCATION)
    if not os.access(script_path, os.X_OK):
        sys.exit("ERROR: script %s: not executable (chmod +x it)" % SCRIPT_RLOCATION)
    env["TF_BIN"] = tf_bin
    env["TF_MODULE_DIR"] = module_dir
    env["TF_LABEL"] = TF_LABEL
    env["TF_ROOT_NAME"] = TF_ROOT_NAME
    env["TF_ROOT_PACKAGE"] = TF_ROOT_PACKAGE
    env["TF_VERSION"] = TF_VERSION
    env["PATH"] = _bin_dir(scratch, tf_bin) + os.pathsep + env.get("PATH", "")

    # `bazel run` itself starts this process with cwd set to Bazel's own
    # execroot, not wherever the invoking shell actually was - already
    # synthetic and meaningless to a script author, so there's nothing lost
    # by overwriting it here: chdir into the module dir before handing off,
    # so `$TF_BIN plan` just works without needing a `-chdir=...` flag.
    os.chdir(module_dir)
    os.execve(script_path, [script_path] + args, env)


if __name__ == "__main__":
    main()
