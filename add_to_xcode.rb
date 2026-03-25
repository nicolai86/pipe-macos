require 'xcodeproj'

project_path = 'pipe-macos.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Find main target
target = project.targets.find { |t| t.name == 'pipe-macos' }

# Create group if it doesn't exist
main_group = project.main_group.groups.find { |g| g.name == 'pipe-macos' } || project.main_group
ir_group = main_group.groups.find { |g| g.name == 'IR' } || main_group.new_group('IR', 'pipe-macos/IR')

# Add files
%w[MachineCommand.swift GCodeFormatter.swift IRGCodeGenerator.swift].each do |file_name|
  file_path = "pipe-macos/IR/#{file_name}"
  next unless File.exist?(file_path)
  
  file_ref = ir_group.files.find { |f| f.path == file_name } || ir_group.new_file(file_name)
  
  # Add to build phase
  unless target.source_build_phase.files_references.include?(file_ref)
    target.source_build_phase.add_file_reference(file_ref)
  end
end

project.save
puts "Added IR files to Xcode project."
