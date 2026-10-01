# `use`d relative to the root of this repository, rather than relative to
# this file - see nu_library's docs.
use lib/greeting.nu

# Returns an upper-cased greeting for `name`.
export def greet [name: string]: nothing -> string {
    greeting greet $name | str uppercase
}
