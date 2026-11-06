# Checks the rendered deck has its three slides, with both diagrams and
# reveal.js. `data` is available relative to the working directory (this
# test's runfiles tree).
use std/assert

def main [] {
    let site = "slides/public"
    for file in [reveal/reveal.js reveal/theme/white.css diagrams/architecture.svg diagrams/build.svg] {
        assert ($site | path join $file | path exists) $"($file) is missing"
    }

    let deck = (open --raw ($site | path join talks intro index.html))
    assert equal ($deck | split row "<section>" | length) 4 "the deck should have 3 slides"
    for diagram in [architecture build] {
        assert str contains $deck $'src="/diagrams/($diagram).svg"'
    }
}
