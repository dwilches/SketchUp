require 'sketchup.rb'
require 'extensions.rb'


lce = SketchupExtension.new "LaserCuttingExporter", "C:/Users/DWilches/Documents/Hobbies/Public/SketchUp/Plugins/laser_cutting_exporter.rb"
lce.description = "Export your model as a SVG for laser cutting"
Sketchup.register_extension lce, true

