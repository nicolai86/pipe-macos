require 'xcodeproj'
project = Xcodeproj::Project.open('pipe-macos.xcodeproj')

# Define exactly what we want
ir_files = {
  'GCodeGenerating.swift' => 'pipe-macos/IR/GCodeGenerating.swift',
  'MachineCommand.swift' => 'pipe-macos/IR/MachineCommand.swift',
  'GCodeFormatter.swift' => 'pipe-macos/IR/GCodeFormatter.swift',
  'IRGCodeGenerator.swift' => 'pipe-macos/IR/IRGCodeGenerator.swift'
}

# Targets
app_target = project.targets.find { |t| t.name == 'pipe-macos' }
test_target = project.targets.find { |t| t.name == 'pipe-macosTests' }

# 1. REMOVE all existing references to these files to start from a clean state
project.objects.select { |o| o.isa == 'PBXFileReference' && ir_files.keys.include?(o.path.split('/').last) }.each do |ref|
  puts "Removing ref: #{ref.path}"
  ref.remove_from_project
end

# 2. Add them back correctly to the IR group
main_group = project.main_group.groups.find { |g| g.name == 'pipe-macos' || g.path == 'pipe-macos' }
ir_group = main_group.groups.find { |g| g.name == 'IR' } || main_group.new_group('IR', 'pipe-macos/IR')

ir_files.each do |name, path|
  puts "Adding #{name} at #{path}"
  ref = ir_group.new_reference(path)
  app_target.source_build_phase.add_file_reference(ref)
end

project.save
puts "Project structure updated."
