use std/assert

# `use`d relative to this file, rather than to the root of this repository.
use ../lib/greeting.nu
use lib/shout.nu

def main [expected_name: string] {
    assert equal (greeting greet "Bazel") "Hello, Bazel!"
    assert equal (shout greet "Bazel") "HELLO, BAZEL!"

    # `data` files are available via runfiles, relative to the working
    # directory (this target's runfiles tree).
    assert equal (open app/name.txt | str trim) $expected_name

    # The pinned toolchain version, not whatever `nu` might be on PATH.
    assert equal (version | get version) "0.116.0"
}
