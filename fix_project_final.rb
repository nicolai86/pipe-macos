require 'xcodeproj'
project = Xcodeproj::Project.open('pipe-macos.xcodeproj')

# 1. Consolidated IR Group
main_group = project.main_group.groups.find { |g| g.name == 'pipe-macos' || g.path == 'pipe-macos' }
ir_group = main_group.groups.find { |g| g.name == 'IR' } || main_group.new_group('IR', 'pipe-macos/IR')

# 2. Find and Move all IR files into that group
project.objects.select { |o| o.isa == 'PBXFileReference' && o.path =~ /IR/ }.each do |ref|
  # Remove from old parent
  ref.parent.children.delete(ref) if ref.parent
  # Add to new parent
  ir_group.children << ref
end

# 3. Add to App Target
app_target = project.targets.find { |t| t.name == 'pipe-macos' }
ir_group.files.each do |ref|
  unless app_target.source_build_phase.files_references.include?(ref)
    app_target.source_build_phase.add_file_reference(ref)
  end
end

# 4. Remove any duplicate or top-level IR groups
project.main_group.groups.select { |g| g.name == 'IR' && g.parent == project.main_group }.each do |g|
  g.remove_from_project
end

# 5. Clean up tests
test_group = project.main_group.groups.find { |g| g.name == 'pipe-macosTests' || g.path == 'pipe-macosTests' }
test_target = project.targets.find { |t| t.name == 'pipe-macosTests' }
test_ref = test_group.files.find { |f| f.path == 'GCodeGeneratorTests.swift' }
if test_ref && !test_target.source_build_phase.files_references.include?(test_ref)
  test_target.source_build_phase.add_file_reference(test_ref)
end

project.save
