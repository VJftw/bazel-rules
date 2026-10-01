"""Public API: `plantuml_diagram` (renders a `.puml` source into a diagram image)
and `plantuml_library` (a reusable, transitively-composable set of PlantUML
include files).

The actual rule implementations live under `private/` - this file just wires
up the public names.
"""

load("//:private/diagram.bzl", _plantuml_diagram = "plantuml_diagram")
load("//:private/library.bzl", _PlantUMLLibraryInfo = "PlantUMLLibraryInfo", _plantuml_library = "plantuml_library")

PlantUMLLibraryInfo = _PlantUMLLibraryInfo
plantuml_diagram = _plantuml_diagram
plantuml_library = _plantuml_library
