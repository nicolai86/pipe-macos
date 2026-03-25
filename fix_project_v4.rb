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

app_target = project.targets.find { |t| t.name == 'pipe-macos' }

ir_files.each do |name, path|
  # Add directly to main group with path relative to project root
  ref = project.main_group.new_reference(path)
  app_target.source_build_phase.add_file_reference(ref)
end

project.save
