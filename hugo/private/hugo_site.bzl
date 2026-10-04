"""`hugo_site`. Not part of the public API - `//:defs.bzl` re-exports it."""

load("//:private/hugo_binary.bzl", "hugo_binary")
load("//:private/hugo_build.bzl", "hugo_build")

def hugo_site(
        name,
        config,
        srcs,
        base_url = "",
        environment = "production",
        minify = False,
        extra_args = [],
        out = "",
        **kwargs):
    """Renders a Hugo site, and exposes a `<name>_hugo` runnable for local preview.

    A thin macro over two underlying rules: `<name>` itself (`hugo_build` -
    the rendered site, from `bazel build`) and `<name>_hugo` (`hugo_binary` -
    a directly runnable, hermetic `hugo`, pinned to the same toolchain -
    `bazel run //path:<name>_hugo -- server` for live-reloading local
    preview, or any other one-off `hugo` subcommand this module doesn't
    otherwise wrap).

    Args:
        name: the rendered site's own target name.
        config: this site's root Hugo config file (hugo.toml/hugo.yaml/
            hugo.json, or the legacy config.toml/config.yaml/config.json
            name) - its own directory becomes the site's `--source` root.
        srcs: every other file the site needs - content/, layouts/,
            static/, assets/, data/, i18n/, archetypes/, etc.
        base_url: passed via `--baseURL`.
        environment: passed via `--environment` (selects environment-
            specific config overlays, e.g. `config/production/...`) -
            hugo's own CLI default for a plain build (as opposed to `hugo
            server`, which defaults to 'development') is already
            'production'; set explicitly here so a build's output doesn't
            silently depend on an ambient `HUGO_ENVIRONMENT` env var
            instead.
        minify: whether to pass `--minify`.
        extra_args: extra flags passed through to `hugo`, e.g. '--gc' or
            '--cleanDestinationDir'.
        out: output directory name. Defaults to `name`.
        **kwargs: forwarded to both underlying targets - e.g. `visibility`,
            `tags`.
    """
    hugo_build(
        name = name,
        config = config,
        srcs = srcs,
        base_url = base_url,
        environment = environment,
        minify = minify,
        extra_args = extra_args,
        out = out,
        **kwargs
    )
    hugo_binary(
        name = name + "_hugo",
        **kwargs
    )
