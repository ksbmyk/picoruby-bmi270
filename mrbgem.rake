# mrbgem.rake
MRuby::Gem::Specification.new('picoruby-bmi270') do |spec|
  spec.license = 'MIT'
  spec.author  = 'ksbmyk'
  spec.summary = 'BMI270 6-axis IMU driver - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-i2c'
  spec.add_test_dependency 'picoruby-picotest'
end
