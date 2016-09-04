require 'sketchup.rb'
require 'extensions.rb'


MATERIAL_THICKNESS = 3.mm unless defined? MATERIAL_THICKNESS

SVG_HEADER = '<svg version="1.1" baseProfile="full"
    width="300mm" height="200mm"
    xmlns="http://www.w3.org/2000/svg"
    xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd"
    xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape">
    <sodipodi:namedview units="mm" inkscape:document-units="mm"/>
' unless defined? SVG_HEADER

SVG_BEGIN_PATH = "    <path fill='transparent' stroke='blue' style='fill:none;stroke-width:0.1mm' d='" unless defined? SVG_BEGIN_PATH

SVG_END_PATH = "Z' />\n" unless defined? SVG_END_PATH

SVG_FOOTER = "</svg>\n" unless defined? SVG_FOOTER

TO_MM_SCALE = 10 * 2.54 * 3.543 unless defined? TO_MM_SCALE

POINT_MERGE_DISTANCE = 0.00001 unless defined? POINT_MERGE_DISTANCE


def create_toolbar()
    toolbar = UI.toolbar("Laser Cutting Exporter")
    if toolbar.count != 0
        return
    end

    #==========================================================================
    # Config button
    #==========================================================================
    
    cmd = UI::Command.new("show_settings") {
        show_settings()
    }
    path = "images/settings-icon.png" # Sketchup.find_support_file "settings-icon.png", "./"		
    cmd.small_icon = path
    cmd.large_icon = path
    cmd.tooltip = "Settings"
    cmd.status_bar_text = "Configure exporter settings"
    cmd.menu_text = cmd.tooltip

    toolbar = toolbar.add_item cmd
    
    #==========================================================================
    # Export button
    #==========================================================================

    cmd = UI::Command.new("perform_export") {
        perform_export()
    }

    path = "images/laser-icon.png" # Sketchup.find_support_file "export-icon.png", "./"		
    cmd.small_icon = path
    cmd.large_icon = path
    cmd.tooltip = "Export to SVG file"
    cmd.status_bar_text = "Export model for laser cutting it"
    cmd.menu_text = cmd.tooltip
    
    toolbar = toolbar.add_item cmd
    
    return toolbar
end

def get_all_faces()

    # Check we have something selected
    active_model = Sketchup.active_model
    selection = active_model.selection
    
    # If there is a selection, only selected faces will be traversed. If there
    # is no selection then all the faces in the current model are traveresed.
    if selection.length != 0
        entities = selection
    else
        entities = active_model.entities
    end
    
    # Extract all the faces from either the model or the selection
    all_faces = []
    entities.each{ |entity|
        faces = get_faces(entity)
        all_faces.push(*faces)
    }
    
    return all_faces
end

# Returns an array with all the faces in the 'entity'
def get_faces(entity)

    case entity.typename
        when "Face" then
            return [ entity ]
            
        when "Group" then
            all_entities = entity.entities
            
        when "ComponentInstance" then
            all_entities = entity.definition.entities
            
        else
            return []
    end
    
    # Recursively return all the faces encountered inside this entity
    all_faces = []
    all_entities.each{ |entity|
        faces = get_faces(entity)
        all_faces.push(*faces)
    }
    
    return all_faces
end


def svg_export(entities, filename)

    def to_mm_str(number)
        return (number.to_f * TO_MM_SCALE).to_s
    end

    File.open(filename, "w") { |file|
    
        file.write(SVG_HEADER)
        
        curr_x = 0
        new_curr_x = 0
        
        entities.each{ |entity|
        
            # As the points are in coordinates with repect to the face's plane,
            # I need to transform them from that plane to the XY plane. I do
            # this with this inverse transformation. Before outputting each points
            # I will need to transform it by 'face_transform'
            face_transform = Geom::Transformation.new(entity.edges[0].start, entity.normal).inverse
            file.write(SVG_BEGIN_PATH)
            
            entity.loops.each { |loop|
            
                first_pos = nil
                start_pos = nil
                end_pos = nil
                
                loop.edges.each { |edge|
                
                    # Get the start vertex of this edge. This can be edge.end or
                    # edge.start depending on how the edge is used on this face.
                    if edge.reversed_in? entity
                        start_pos = edge.end.position
                    else
                        start_pos = edge.start.position
                    end
                    # Transform the vertex to the plane XY
                    start_pos = start_pos.transform(face_transform)
                    
                    # If this is the first point of the loop, or if the previous
                    # point lies too far from the current one, then issue a move
                    # command. Otherwise, ignore the start point, it is already
                    # in the path.
                    if end_pos == nil || start_pos.distance(end_pos) > POINT_MERGE_DISTANCE
                        file.write("M " + to_mm_str(curr_x + start_pos.x) + " " + to_mm_str(start_pos.y) + " ")
                        
                        if curr_x + start_pos.x.abs > new_curr_x
                            new_curr_x = curr_x + start_pos.x.abs
                        end
                    end
                    
                    # Get the end vertex of this edge.
                    if edge.reversed_in? entity
                        end_pos = edge.start.position
                    else
                        end_pos = edge.end.position
                    end
                    # Transform the vertex to the plane XY
                    end_pos = end_pos.transform(face_transform)
                    
                    # Create a new line segment towards the end vertex
                    file.write("L " + to_mm_str(curr_x + end_pos.x) + " " + to_mm_str(end_pos.y) + " ")
                    
                    if curr_x + end_pos.x.abs > new_curr_x
                        new_curr_x = curr_x + end_pos.x.abs
                    end
                    
                    # Record the first edge of all to determine at the end if a
                    # closed loop is needed
                    if first_pos == nil
                        first_pos = start_pos
                    end
                }
                
                # If the first and last vertex of the loop are very close together, issue a "close loop"command
                if first_pos.distance(end_pos) < POINT_MERGE_DISTANCE
                    file.write("Z ")
                end
            }
            
            # Closes the path tag
            file.write(SVG_END_PATH)
            
            # The new entity must be shifted a little
            curr_x = new_curr_x
        }
        
        file.write(SVG_FOOTER)
    }

end


def perform_export()
    selection = Sketchup.active_model.selection

    faces = get_all_faces()

    selection.clear

    # From all the faces we have found, add to the selection only those that
    # correspond to the piece that must be cut. I know how to differentiate
    # them with some heuristics (may not be perfect yet):
    #
    #   - Every face with more/less than 4 sides must be laser-cut
    #   - The pieces that have 4 sides and 2 of them are of length
    #     MATERIAL_THICKNESS must not be laser-cut
    #
    faces.each{ |f|
        # Every face with more/less than 4 sides must be laser-cut
        if f.edges.length != 4
            selection.add(f)
        end
        
        # The pieces that have 4 sides and 2 of them are of length
        # MATERIAL_THICKNESS must not be laser-cut. I check that these sides must
        # be at opposite positions
        edges = f.outer_loop.edges
        
        if (edges[0].length == MATERIAL_THICKNESS && edges[2].length == MATERIAL_THICKNESS) ||
           (edges[1].length == MATERIAL_THICKNESS && edges[3].length == MATERIAL_THICKNESS)
            # It is a border, don't add it
        else
            selection.add(f)
        end
    }


    if faces != nil && faces != []
        path_to_save_to = UI.savepanel("Save Image File", nil, "*.svg")
        
        svg_export(selection, path_to_save_to)
        puts("Saved")
    end
end

def show_settings()
    require 'json'
    
    dialog = UI::WebDialog.new("Settings", true, "Settings_Laser_Cutting_Exporter", 580, 550, 200, 200, true)
    
    dialog.add_action_callback("return_settings_to_sketchup") do |dialog, params|
        UI.messagebox("return_settings_to_sketchup: " + params.to_s)
    end
    dialog.add_action_callback("show_file_dialog") do |dialog, params|
        UI.messagebox("show_file_dialog: " + params.to_s)
    end

    # Find and show our html file
    html_path = "C:/Users/DWilches/Documents/SketchUp/settings_dialog.html" # Sketchup.find_support_file "settings_dialog.html", "Plugins"
    dialog.set_file(html_path)
    # Show the dialog and run an initial block to populate the layers
    dialog.show() {
        # Obtain the list of layers
        layers = []
        Sketchup.active_model.layers.each{ |layer| layers.push(layer.name) }
        # Convert the list of layers to a JSON string
        layers_str = JSON.generate(layers)
        dialog.execute_script("set_initial_layers('"+ layers_str + "')")
    }
    
    

end

create_toolbar()















