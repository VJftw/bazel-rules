"""Public API: `hugo_site` - renders a Hugo site into a directory of static
files (the `<name>` target) and exposes a directly runnable, hermetic `hugo`
for local preview (the `<name>_hugo` target).

The actual rule implementations live under `private/` - this file just wires
up the public name.
"""

load("//:private/hugo_site.bzl", _hugo_site = "hugo_site")

hugo_site = _hugo_site
