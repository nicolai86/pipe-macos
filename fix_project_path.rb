require 'xcodeproj'
project = Xcodeproj::Project.open('pipe-macos.xcodeproj')

# 1. Consolidated IR Group
main_group = project.main_group.groups.find { |g| g.name == 'pipe-macos' || g.path == 'pipe-macos' }
ir_group = main_group.groups.find { |g| g.name == 'IR' } || main_group.new_group('IR', 'pipe-macos/IR')

# 2. Files to Fix
ir_files = ['GCodeGenerating.swift', 'MachineCommand.swift', 'GCodeFormatter.swift', 'IRGCodeGenerator.swift']

# 3. Targets
app_target = project.targets.find { |t| t.name == 'pipe-macos' }
test_target = project.targets.find { |t| t.name == 'pipe-macosTests' }

# 4. Remove ALL other references to these files from EVERYWHERE in the project
project.objects.select { |o| o.isa == 'PBXFileReference' && ir_files.include?(o.path.split('/').last) }.each do |ref|
  puts "Checking ref: #{ref.path}"
  if ref.path != "pipe-macos/IR/#{ref.path.split('/').last}" && ref.path != ref.path.split('/').last
     puts "Removing bad ref: #{ref.path}"
     ref.remove_from_project
  end
end

# 5. Add them correctly to the IR group
ir_files.each do |f|
  puts "Adding #{f} to IR group"
  # Check if it's already there
  ref = ir_group.files.find { |file| file.path == f || file.name == f }
  unless ref
    ref = ir_group.new_file(f)
  end
  
  # Ensure it's in the app target
  unless app_target.source_build_phase.files_references.include?(ref)
    puts "Adding #{f} to app target"
    app_target.source_build_phase.add_file_reference(ref)
  end
end

project.save
puts "Project paths fixed."
