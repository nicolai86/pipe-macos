require 'xcodeproj'
project = Xcodeproj::Project.open('pipe-macos.xcodeproj')

files_to_move = {
  'GCodeGenerator.swift' => 'pipe-macos/GCodeGenerator.swift',
  'MachineCommand.swift' => 'pipe-macos/MachineCommand.swift',
  'GCodeFormatter.swift' => 'pipe-macos/GCodeFormatter.swift',
  'GCodeGenerating.swift' => 'pipe-macos/GCodeGenerating.swift'
}

# 1. REMOVE all existing references to these files and any 'IR' path
project.objects.select { |o| o.isa == 'PBXFileReference' && (files_to_move.keys.include?(o.path.split('/').last) || o.path =~ /IR/) }.each do |ref|
  puts "Removing ref: #{ref.path}"
  ref.remove_from_project
end

# 2. Also remove any IR groups
project.main_group.groups.select { |g| g.name == 'IR' || g.path == 'IR' || g.path =~ /IR/ }.each do |g|
  puts "Removing group: #{g.name || g.path}"
  g.remove_from_project
end

# 3. Add them back correctly to the main group
app_target = project.targets.find { |t| t.name == 'pipe-macos' }
main_group = project.main_group.groups.find { |g| g.name == 'pipe-macos' || g.path == 'pipe-macos' }

files_to_move.each do |name, path|
  puts "Adding #{name} at #{path}"
  # We use path relative to the group it's in. main_group has path 'pipe-macos'
  ref = main_group.new_reference(name)
  app_target.source_build_phase.add_file_reference(ref)
end

project.save
puts "Project structure updated with final naming."
