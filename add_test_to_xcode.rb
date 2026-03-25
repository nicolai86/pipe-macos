require 'xcodeproj'
project_path = 'pipe-macos.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'pipe-macosTests' }
group = project.main_group.groups.find { |g| g.name == 'pipe-macosTests' }
file_ref = group.new_file('IRGCodeGeneratorTests.swift')
target.source_build_phase.add_file_reference(file_ref)
project.save
