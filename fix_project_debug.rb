require 'xcodeproj'
project = Xcodeproj::Project.open('pipe-macos.xcodeproj')

def print_groups(group, indent=0)
  puts "#{"  " * indent} Group: #{group.name || group.path}"
  group.files.each { |f| puts "#{"  " * (indent+1)} File: #{f.name || f.path}" }
  group.groups.each { |g| print_groups(g, indent + 1) }
end

print_groups(project.main_group)

# Implementation
main_group = project.main_group.groups.find { |g| g.name == 'pipe-macos' || g.path == 'pipe-macos' }
ir_group = main_group.groups.find { |g| g.name == 'IR' || g.path == 'pipe-macos/IR' }
test_group = project.main_group.groups.find { |g| g.name == 'pipe-macosTests' || g.path == 'pipe-macosTests' }

app_target = project.targets.find { |t| t.name == 'pipe-macos' }
test_target = project.targets.find { |t| t.name == 'pipe-macosTests' }

['GCodeGenerating.swift', 'MachineCommand.swift', 'GCodeFormatter.swift', 'IRGCodeGenerator.swift'].each do |f|
  ref = ir_group.files.find { |file| file.path == f || file.name == f }
  if ref
    unless app_target.source_build_phase.files_references.include?(ref)
      app_target.source_build_phase.add_file_reference(ref)
    end
  end
end

test_ref = test_group.files.find { |f| f.path == 'GCodeGeneratorTests.swift' || f.name == 'GCodeGeneratorTests.swift' }
if test_ref && !test_target.source_build_phase.files_references.include?(test_ref)
  test_target.source_build_phase.add_file_reference(test_ref)
end

project.save
