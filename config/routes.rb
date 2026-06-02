# frozen_string_literal: true

# Routes are declared in Mbeditor::ROUTE_MAP (lib/mbeditor/route_map.rb), the
# single source of truth shared with the private, isolated route set. Drawing
# from it here keeps the engine route set and the private set from drifting.
Mbeditor::Engine.routes.draw(&Mbeditor::ROUTE_MAP)
