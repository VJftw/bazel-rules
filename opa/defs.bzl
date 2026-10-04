"""Public API: `opa_build` (packages Rego policies into an OPA bundle),
`opa_eval` (evaluates a Rego query into a single result file), and
`opa_test` (runs `opa test` as a real `bazel test`).

The actual rule implementations live under `private/` - this file just wires
up the public names.
"""

load("//:private/opa_build.bzl", _opa_build = "opa_build")
load("//:private/opa_eval.bzl", _opa_eval = "opa_eval")
load("//:private/opa_test.bzl", _opa_test = "opa_test")

opa_build = _opa_build
opa_eval = _opa_eval
opa_test = _opa_test
