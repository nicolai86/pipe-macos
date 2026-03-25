require 'xcodeproj'
project = Xcodeproj::Project.open('pipe-macos.xcodeproj')

def find_group(parent, name)
  parent.groups.find { |g| g.name == name || g.path == name }
end

main_group = find_group(project.main_group, 'pipe-macos')
ir_group = find_group(main_group, 'IR')
test_group = find_group(project.main_group, 'pipe-macosTests')

app_target = project.targets.find { |t| t.name == 'pipe-macos' }
test_target = project.targets.find { |t| t.name == 'pipe-macosTests' }

puts "Groups found: main=\(main_group.name rescue 'nil'), ir=\(ir_group.name rescue 'nil'), test=\(test_group.name rescue 'nil')"

# Cleanup main target source phase from missing files or wrong paths
app_target.source_build_phase.files_references.each do |ref|
  if ref && ref.path == 'GCodeGenerating.swift' && (ref.parent.nil? || ref.parent.path != 'IR')
     puts "Removing bad ref: \(ref.path)"
     app_target.source_build_phase.remove_file_reference(ref)
  end
end

# Add IR files to app target
['GCodeGenerating.swift', 'MachineCommand.swift', 'GCodeFormatter.swift', 'IRGCodeGenerator.swift'].each do |f|
  ref = ir_group.files.find { |file| file.path == f }
  if ref
    unless app_target.source_build_phase.files_references.include?(ref)
      puts "Adding \(f) to app target"
      app_target.source_build_phase.add_file_reference(ref)
    end
  else
    puts "Warning: \(f) not found in IR group"
  end
end

# Cleanup test target
bad_ref = test_group.files.find { |f| f.path == 'IRGCodeGeneratorTests.swift' }
if bad_ref
  puts "Removing IRGCodeGeneratorTests.swift from project"
  test_target.source_build_phase.remove_file_reference(bad_ref)
  bad_ref.remove_from_project
end

test_ref = test_group.files.find { |f| f.path == 'GCodeGeneratorTests.swift' }
if test_ref && !test_target.source_build_phase.files_references.include?(test_ref)
  puts "Ensuring GCodeGeneratorTests.swift is in test target"
  test_target.source_build_phase.add_file_reference(test_ref)
end

project.save
