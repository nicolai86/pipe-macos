require 'xcodeproj'
project = Xcodeproj::Project.open('pipe-macos.xcodeproj')
target = project.targets.find { |t| t.name == 'pipe-macos' }

# Remove incorrect reference
target.source_build_phase.files_references.each do |ref|
  if ref && ref.path == 'GCodeGenerating.swift' && ref.parent && ref.parent.path != 'pipe-macos/IR'
    target.source_build_phase.remove_file_reference(ref)
  end
end

# Find or create IR group
main_group = project.main_group.groups.find { |g| g.name == 'pipe-macos' } || project.main_group
ir_group = main_group.groups.find { |g| g.name == 'IR' } || main_group.new_group('IR', 'pipe-macos/IR')

# Add correct reference
file_name = 'GCodeGenerating.swift'
file_ref = ir_group.files.find { |f| f.path == file_name } || ir_group.new_file(file_name)

unless target.source_build_phase.files_references.include?(file_ref)
  target.source_build_phase.add_file_reference(file_ref)
end

# Remove old IRGCodeGeneratorTests.swift if it was added incorrectly
test_target = project.targets.find { |t| t.name == 'pipe-macosTests' }
test_group = project.main_group.groups.find { |g| g.name == 'pipe-macosTests' }
bad_ref = test_group.files.find { |f| f.path == 'IRGCodeGeneratorTests.swift' }
if bad_ref
  test_target.source_build_phase.remove_file_reference(bad_ref)
  bad_ref.remove_from_project
end

project.save
