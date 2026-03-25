content = File.read('pipe-macosTests/GCodeGeneratorTests.swift')
base_methods = content.scan(/func (base_test\w+)/).flatten

def generate_subclass(name, generator_class, base_methods)
  methods = base_methods.map { |m| "    func #{m.sub('base_', '')}() { #{m}() }" }.join("\n")
  <<~SWIFT
  final class #{name}: GCodeGeneratorTests {
      override func makeGenerator() -> GCodeGenerating { return #{generator_class}() }
  #{methods}
  }
  SWIFT
end

legacy_subclass = generate_subclass('LegacyGCodeGeneratorSuiteTests', 'GCodeGenerator', base_methods)
ir_subclass = generate_subclass('IRGCodeGeneratorSuiteTests', 'IRGCodeGenerator', base_methods)

# Extract everything up to the first subclass definition
header = content.split('final class LegacyGCodeGeneratorTests').first

# Find the extra tests in IRGCodeGeneratorSuiteTests that were there before
extra_ir_tests = content.scan(/func (testIRMatchesLegacyExactly\(\) \{.*?^\s*\}|testPerimeterMappingRoundTrip\(\) \{.*?^\s*\})/m)
ir_subclass_body = ir_subclass.sub(/\}$/, extra_ir_tests.flatten.join("\n\n") + "\n}")

new_content = header + legacy_subclass + "\n" + ir_subclass_body
File.write('pipe-macosTests/GCodeGeneratorTests.swift', new_content)
