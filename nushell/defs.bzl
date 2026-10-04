"""Public API: `nu_library` (a reusable, transitively-composable set of
Nushell modules), `nu_binary` (a Nushell script, runnable via `bazel run`)
and `nu_test` (a Nushell script run as a real `bazel test`).

The actual rule implementations live under `private/` - this file just wires
up the public names.
"""

load("//:private/library.bzl", _NuLibraryInfo = "NuLibraryInfo", _nu_library = "nu_library")
load("//:private/nu_binary.bzl", _nu_binary = "nu_binary", _nu_test = "nu_test")

NuLibraryInfo = _NuLibraryInfo
nu_binary = _nu_binary
nu_library = _nu_library
nu_test = _nu_test
