# picoruby-bmi270

A pure Ruby implementation of the BMI270 6-axis IMU driver for PicoRuby.

> **MPU6886 compatibility:** this gem mirrors the public API of
> [picoruby-mpu6886](https://github.com/bash0C7/picoruby-mpu6886)
> (`IMU.new(i2c)` + `imu.acceleration` / `gyroscope` / `temperature`). On boards
> where the IMU changed from MPU6886 to BMI270 (ATOM Matrix v1.1, AtomS3R), your
> code only needs to swap the class name `MPU6886` → `BMI270`.

## Installation

Register via [picoruby/runtimegems](https://github.com/picoruby/runtimegems)
(add a `picoruby-bmi270.yaml` pointing at this repo), or add it to your PicoRuby
build configuration directly:

```ruby
conf.gem github: 'ksbmyk/picoruby-bmi270', branch: 'main'
```

## Dependencies

- `picoruby-i2c`: I2C communication library (included in PicoRuby)

## Quick Start

```ruby
require 'i2c'
require 'bmi270'

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000, sda_pin: 25, scl_pin: 21)
imu = BMI270.new(i2c)   # uploads the config firmware during init

accel = imu.acceleration  # => {x: 0.1, y: 0.0, z: 1.0} (G)
gyro  = imu.gyroscope     # => {x: 1.2, y: -0.5, z: 0.0} (deg/s)
temp  = imu.temperature   # => 25.4 (°C)
```

> **Init note:** unlike the MPU6886, the BMI270 requires an ~8KB configuration
> firmware to be uploaded over I2C when `BMI270.new` runs. This adds a short
> delay (typically well under a second) to construction. The blob lives in
> `mrblib/bmi270_config.rb`.

## Atomic burst read

`snapshot` issues a single 24-byte I2C burst that captures all three sensors
atomically. `read_all` is an alias kept for MPU6886 compatibility.

```ruby
snap = imu.snapshot
# => { accel: {x:, y:, z:}, gyro: {x:, y:, z:}, temp: Float }

data = imu.read_all  # alias of snapshot
```

## Background sampler Task

Spawn a background Task that keeps the latest reading fresh while your main loop
does other work.

```ruby
imu = BMI270.new(i2c)
imu.start_sampling(interval_ms: 20)   # 50 Hz background sampling

loop do
  accel = imu.latest_acceleration       # cached; no I2C from this thread
  puts "X=#{accel[:x]}" if accel
  sleep_ms 100
end

imu.stop_sampling
```

Cached accessors (require prior `start_sampling` or `tick`):

```ruby
imu.fresh?                 # true once at least one sample has been cached
imu.latest_snapshot        # last full snapshot, or nil
imu.latest_acceleration    # last accel hash, or nil
imu.latest_gyroscope       # last gyro hash, or nil
imu.latest_temperature     # last temp float, or nil
```

## Tick-driven sampler

Keep your main loop in charge and call `tick` instead of a background Task.

```ruby
imu = BMI270.new(i2c)
imu.configure_sampling(interval_ms: 20)

loop do
  imu.tick                              # samples if interval elapsed; else no-op
  accel = imu.latest_acceleration
  puts "X=#{accel[:x]}" if accel
  sleep_ms 5
end
```

## Range configuration

```ruby
imu.accel_range = BMI270::ACCEL_RANGE_2G    # ±2G (default)
imu.accel_range = BMI270::ACCEL_RANGE_4G    # ±4G
imu.accel_range = BMI270::ACCEL_RANGE_8G    # ±8G
imu.accel_range = BMI270::ACCEL_RANGE_16G   # ±16G

imu.gyro_range = BMI270::GYRO_RANGE_250DPS   # ±250°/s (default)
imu.gyro_range = BMI270::GYRO_RANGE_500DPS
imu.gyro_range = BMI270::GYRO_RANGE_1000DPS
imu.gyro_range = BMI270::GYRO_RANGE_2000DPS
imu.gyro_range = BMI270::GYRO_RANGE_125DPS   # BMI270-only, no MPU6886 equivalent
```

## Motion analysis

```ruby
imu.magnitude               # Float (combined acceleration in G)
imu.tilt_angles             # {pitch:, roll:} (degrees)
imu.motion_detected?        # bool, default threshold 0.1G
imu.motion_detected?(0.2)   # bool, custom threshold
```

## Error handling

Communication errors raise `IOError`. Initialization failure (wrong chip ID, or
the config load never reaching `init_ok`) raises `RuntimeError`.

```ruby
begin
  imu = BMI270.new(i2c)
  accel = imu.acceleration
rescue IOError => e
  puts "Sensor communication error: #{e.message}"
rescue => e
  puts "Unexpected error: #{e.message}"
end
```

## Development

Host-side test suite uses CRuby + test-unit with a hand-rolled I2C double:

```bash
bundle install
bundle exec rake test
```

Tests cover the config firmware blob (size and boundary bytes), the init/upload
sequence, narrow reads, the burst snapshot, `read_all`, the tick-driven sampler,
range setters, and motion analysis. The background `start_sampling` Task path is
validated on real hardware, not host-side, because it depends on the mruby/c
task scheduler.

## License

MIT for the driver. The bundled BMI270 configuration firmware
(`mrblib/bmi270_config.rb`) is derived from the Bosch Sensortec BMI270_SensorAPI
and is distributed under its original BSD-3-Clause license. See
[LICENSE](LICENSE) for details.
