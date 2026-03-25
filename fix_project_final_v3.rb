require 'xcodeproj'
project = Xcodeproj::Project.open('pipe-macos.xcodeproj')

ir_files = {
  'GCodeGenerating.swift' => 'pipe-macos/IR/GCodeGenerating.swift',
  'MachineCommand.swift' => 'pipe-macos/IR/MachineCommand.swift',
  'GCodeFormatter.swift' => 'pipe-macos/IR/GCodeFormatter.swift',
  'IRGCodeGenerator.swift' => 'pipe-macos/IR/IRGCodeGenerator.swift'
}

# 1. REMOVE all existing references to these files
project.objects.select { |o| o.isa == 'PBXFileReference' && ir_files.keys.include?(o.path.split('/').last) }.each do |ref|
  ref.remove_from_project
end

# 2. Add them back relative to project root
app_target = project.targets.find { |t| t.name == 'pipe-macos' }
main_group = project.main_group.groups.find { |g| g.name == 'pipe-macos' }
ir_group = main_group.groups.find { |g| g.name == 'IR' } || main_group.new_group('IR', 'IR')

ir_files.each do |name, path|
  # Path in project needs to be relative to the group it's in if the group has a path
  # or relative to project root if group has no path.
  # Our main_group 'pipe-macos' has path 'pipe-macos'.
  # Our ir_group 'IR' is inside main_group.
  
  # Simplest: add to project.main_group with full relative path from root
  ref = project.main_group.new_reference(path)
  app_target.source_build_phase.add_file_reference(ref)
end

project.save
