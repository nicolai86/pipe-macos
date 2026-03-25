require 'xcodeproj'
project = Xcodeproj::Project.open('pipe-macos.xcodeproj')
target = project.targets.find { |t| t.name == 'pipe-macos' }
ir_group = project.main_group.find_subpath('pipe-macos/IR', true)
file_ref = ir_group.find_file_by_path('GCodeGenerating.swift') || ir_group.new_file('GCodeGenerating.swift')
target.source_build_phase.add_file_reference(file_ref)
project.save
