"""Module extension that fetches the PlantUML jar and registers it as a toolchain.

PlantUML ships as a single, platform-independent jar (run by any JVM), so -
unlike a native-binary tool - there's no per-platform fetch matrix here: one
`plantuml.version()` tag downloads one jar into the generated `@plantuml`
repository, wrapped by a single `plantuml_toolchain` and registered as a
`toolchain()` for `//:toolchain_type` (see BUILD.bazel and toolchain.bzl).
Actually running the jar needs a JVM, resolved separately at build time via
Bazel's own built-in `@bazel_tools//tools/jdk:runtime_toolchain_type`
toolchain (see private/diagram.bzl) - so this module needs no `bazel_dep` on
`rules_java` (or similar) just to get one.
"""

load("//:private/versions.bzl", "PLANTUML_VERSIONS")

_DEFAULT_URL_TEMPLATE = "https://repo1.maven.org/maven2/net/sourceforge/plantuml/plantuml/{version}/plantuml-{version}.jar"

# Canonical (repo-mapping-independent) labels for the targets in this module
# that the generated repository's BUILD.bazel needs to reference. Computed
# here - inside the rules_plantuml module - so they resolve correctly no
# matter what name a consumer gives this module via bazel_dep(repo_name = ...).
_TOOLCHAIN_BZL = str(Label("//:toolchain.bzl"))
_TOOLCHAIN_TYPE = str(Label("//:toolchain_type"))

def _plantuml_repo_impl(rctx):
    url = (rctx.attr.url_template or _DEFAULT_URL_TEMPLATE).format(version = rctx.attr.version)
    rctx.download(
        url = url,
        output = "plantuml.jar",
        sha256 = rctx.attr.sha256,
    )
    rctx.file("BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

load("{toolchain_bzl}", "plantuml_toolchain")

plantuml_toolchain(
    name = "plantuml_toolchain",
    jar = "plantuml.jar",
    version = "{version}",
)

toolchain(
    name = "toolchain",
    toolchain = ":plantuml_toolchain",
    toolchain_type = "{toolchain_type}",
)
""".format(toolchain_bzl = _TOOLCHAIN_BZL, version = rctx.attr.version, toolchain_type = _TOOLCHAIN_TYPE))

_plantuml_repo = repository_rule(
    implementation = _plantuml_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "sha256": attr.string(doc = "The jar's sha256, for supply-chain integrity."),
        "url_template": attr.string(),
    },
    doc = "Downloads the requested PlantUML jar and wraps it in a `plantuml_toolchain` + `toolchain()`.",
)

def _plantuml_ext_impl(module_ctx):
    tag = None
    for mod in module_ctx.modules:
        # Only the root module's own request applies, the same way a library
        # dependency can't unilaterally decide what version every consumer's
        # build renders diagrams with.
        if not mod.is_root:
            continue
        for t in mod.tags.version:
            if tag != None:
                fail("plantuml.version was declared more than once - only one is allowed.")
            tag = t

    if tag == None:
        fail("No plantuml.version(...) tag declared by the root module - a PlantUML version must be requested, e.g. plantuml.version(version = \"8059\").")

    # An explicit sha256 always wins. Otherwise, fall back to the generated
    # mirror in private/versions.bzl (see scripts/mirror_plantuml_versions.py)
    # - but only for the default (Maven Central) URL: that mirror's checksum
    # is for that specific jar, so it'd be meaningless (and wrong) for a
    # version fetched from a `url_template` override.
    sha256 = tag.sha256 or ("" if tag.url_template else PLANTUML_VERSIONS.get(tag.version, ""))

    _plantuml_repo(
        name = "plantuml",
        version = tag.version,
        sha256 = sha256,
        url_template = tag.url_template,
    )

_version_tag = tag_class(
    doc = """Requests the PlantUML version to fetch and register as a toolchain.

    Fetched from Maven Central by default
    (`repo1.maven.org/maven2/net/sourceforge/plantuml/plantuml/<version>/plantuml-<version>.jar`)
    - `url_template` overrides this, e.g. to pin a different mirror. Only
    takes effect from the root module, and only once - declaring it more
    than once (even across separate `bazel_dep`s) is a build error, and one
    from a dependency is silently ignored, so a library you depend on can't
    unilaterally change what PlantUML version the rest of your build renders
    diagrams with.
    """,
    attrs = {
        "version": attr.string(mandatory = True, doc = "PlantUML version, e.g. '8059' (see https://repo1.maven.org/maven2/net/sourceforge/plantuml/plantuml/maven-metadata.xml for available versions)."),
        "sha256": attr.string(doc = "The jar's sha256, for supply-chain integrity. Optional for any version already in private/versions.bzl (a mirror covering every published version, computed by downloading and hashing each jar - see scripts/mirror_plantuml_versions.py, since Maven Central publishes no checksum/signature for this artifact at all) as long as `url_template` isn't set (that mirror's checksums are for the real Maven Central artifact specifically) - otherwise required."),
        "url_template": attr.string(
            doc = "Override the download URL - a string with a literal '{version}' placeholder, substituted via Python-style `.format()`. Defaults to the Maven Central artifact URL. Setting this disables the private/versions.bzl mirror default for `sha256` (see above), since that mirror is specific to the real Maven Central artifact.",
        ),
    },
)

plantuml = module_extension(
    implementation = _plantuml_ext_impl,
    tag_classes = {"version": _version_tag},
)
