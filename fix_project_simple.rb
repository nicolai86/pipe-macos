require 'xcodeproj'
project = Xcodeproj::Project.open('pipe-macos.xcodeproj')

# Main App Target
app_target = project.targets.find { |t| t.name == 'pipe-macos' }
main_group = project.main_group.groups.find { |g| g.name == 'pipe-macos' }
ir_group = main_group.groups.find { |g| g.name == 'IR' }

['GCodeGenerating.swift', 'MachineCommand.swift', 'GCodeFormatter.swift', 'IRGCodeGenerator.swift'].each do |f|
  ref = ir_group.files.find { |file| file.path == f }
  if ref && !app_target.source_build_phase.files_references.include?(ref)
    app_target.source_build_phase.add_file_reference(ref)
  end
end

# Test Target
test_target = project.targets.find { |t| t.name == 'pipe-macosTests' }
test_group = project.main_group.groups.find { |g| g.name == 'pipe-macosTests' }

# Ensure IRGCodeGeneratorTests.swift is GONE from project
bad_ref = test_group.files.find { |f| f.path == 'IRGCodeGeneratorTests.swift' }
if bad_ref
  test_target.source_build_phase.remove_file_reference(bad_ref)
  bad_ref.remove_from_project
end

# Ensure GCodeGeneratorTests.swift is in the test target
test_ref = test_group.files.find { |f| f.path == 'GCodeGeneratorTests.swift' }
if test_ref && !test_target.source_build_phase.files_references.include?(test_ref)
  test_target.source_build_phase.add_file_reference(test_ref)
end

project.save
