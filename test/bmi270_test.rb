# test/bmi270_test.rb
$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)

# PicoRuby shim: sleep_ms is a Kernel-level method on-device.
# Under CRuby it does not exist; stub it as a no-op for host tests.
module Kernel
  def sleep_ms(_ms); end
end

# PicoRuby shim: 'i2c' is provided by the picoruby runtime as a built-in.
# Under CRuby that file does not exist; mark it as already loaded so that
# `require 'i2c'` in mrblib/bmi270.rb is a no-op for host tests.
$LOADED_FEATURES << "i2c" unless $LOADED_FEATURES.include?("i2c")

# PicoRuby shim: Machine.uptime_us is the on-device monotonic microsecond
# clock. _now_ms calls it directly. Stub it for host tests.
unless defined?(Machine)
  module Machine
    def self.uptime_us
      0
    end
  end
end

require "test/unit"

class FakeI2C
  attr_reader :writes, :reads

  def initialize
    @writes = []
    @reads = []
    @read_queue = []
  end

  # Queue a canned response (a String of bytes) for the next read call.
  def queue_read(bytes)
    @read_queue << bytes
  end

  def write(addr, *args, **opts)
    @writes << { addr: addr, args: args, opts: opts }
    # Emulate picoruby-i2c: return the number of bytes written (>0 on success).
    count = 0
    args.each do |a|
      case a
      when Array then count += a.size
      when String then count += a.bytesize
      else count += 1
      end
    end
    count
  end

  def read(addr, length, reg = nil, **opts)
    @reads << { addr: addr, length: length, reg: reg, opts: opts }
    @read_queue.shift || ("\x00".b * length)
  end
end

# Queue the canned reads a full BMI270#initialize consumes:
#   1. CHIP_ID  -> 0x24
#   2. INTERNAL_STATUS -> 0x01 (init_ok on first poll)
def queue_init_reads(i2c)
  i2c.queue_read("\x24".b)   # REG_CHIP_ID
  i2c.queue_read("\x01".b)   # REG_INTERNAL_STATUS (init_ok)
end

require "bmi270_config"
require "bmi270"

class BMI270ConfigFileTest < Test::Unit::TestCase
  def test_config_file_is_8192_bytes
    assert_equal 8192, BMI270::CONFIG_FILE.bytesize
  end

  def test_config_file_head_and_tail_match_bosch_array
    bytes = BMI270::CONFIG_FILE.bytes
    assert_equal [0xc8, 0x2e, 0x00, 0x2e], bytes[0, 4]
    assert_equal [0x80, 0x2e, 0x00, 0xc1], bytes[-4, 4]
  end
end

class BMI270InitTest < Test::Unit::TestCase
  def test_init_verifies_chip_id_and_uploads_config
    i2c = FakeI2C.new
    queue_init_reads(i2c)
    BMI270.new(i2c)

    # First read must be the chip ID at register 0x00.
    first = i2c.reads.first
    assert_equal 0x68, first[:addr]
    assert_equal 0x00, first[:reg]

    # A soft reset (CMD=0xB6 to reg 0x7E) must be issued.
    reset = i2c.writes.find { |w| w[:args][0] == 0x7E }
    assert_equal 0xB6, reset[:args][1]

    # The full 8192-byte config must be written to INIT_DATA (reg 0x5E).
    config_bytes = i2c.writes
                      .select { |w| w[:args][0] == 0x5E }
                      .map { |w| w[:args][1].bytesize }
                      .sum
    assert_equal 8192, config_bytes
  end

  def test_init_raises_on_wrong_chip_id
    i2c = FakeI2C.new
    i2c.queue_read("\x00".b)  # wrong chip ID
    assert_raise(RuntimeError) do
      BMI270.new(i2c)
    end
  end

  def test_init_raises_when_internal_status_never_ok
    i2c = FakeI2C.new
    i2c.queue_read("\x24".b)  # chip ID ok
    # never queue a 0x01 status -> reads default to 0x00 -> timeout
    assert_raise(RuntimeError) do
      BMI270.new(i2c)
    end
  end
end

class BMI270InitSamplerStateTest < Test::Unit::TestCase
  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @imu = BMI270.new(@i2c)
  end

  def test_latest_is_nil_after_init
    assert_nil @imu.instance_variable_get(:@latest)
  end

  def test_latest_at_ms_is_zero_after_init
    assert_equal 0, @imu.instance_variable_get(:@latest_at_ms)
  end

  def test_default_sampler_interval_ms_is_20
    assert_equal 20, @imu.instance_variable_get(:@sampler_interval_ms)
  end

  def test_sampler_task_is_nil_after_init
    assert_nil @imu.instance_variable_get(:@sampler_task)
  end

  def test_sampler_running_is_false_after_init
    assert_equal false, @imu.instance_variable_get(:@sampler_running)
  end
end

class BMI270SnapshotTest < Test::Unit::TestCase
  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @imu = BMI270.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_snapshot_issues_one_24_byte_read_at_acc_x_lsb
    # 24-byte little-endian payload: ax=1g, rest 0, temp raw=0 -> 23.0 C
    # ACCEL_RANGE_2G scale = 16384 -> 1g = 0x4000 -> LSB 0x00, MSB 0x40
    payload = [
      0x00, 0x40,   # ax = 16384  -> 1.0g
      0x00, 0x00,   # ay = 0
      0x00, 0x00,   # az = 0
      0x00, 0x00,   # gx = 0
      0x00, 0x00,   # gy = 0
      0x00, 0x00,   # gz = 0
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00,   # sensortime + event (6B)
      0x00, 0x00, 0x00, 0x00,               # int_status + sc (4B)
      0x00, 0x00,   # temperature raw = 0 -> 23.0 C
    ].pack("C*")
    @i2c.queue_read(payload)

    snap = @imu.snapshot

    assert_equal 1, @i2c.reads.size, "expected exactly one I2C read"
    r = @i2c.reads.first
    assert_equal 0x68, r[:addr]
    assert_equal 24,   r[:length]
    assert_equal 0x0C, r[:reg], "burst must start at REG_ACC_X_LSB"

    assert_in_delta 1.0,  snap[:accel][:x], 1e-6
    assert_in_delta 0.0,  snap[:accel][:y], 1e-6
    assert_in_delta 0.0,  snap[:accel][:z], 1e-6
    assert_in_delta 23.0, snap[:temp], 1e-6
    assert_in_delta 0.0,  snap[:gyro][:x], 1e-6
  end

  def test_snapshot_handles_negative_axis_values
    payload = [
      0x00, 0xC0,   # ax = 0xC000 -> -16384 -> -1.0g at +/-2G
      0x00, 0x00, 0x00, 0x00,   # ay, az
      0x80, 0xFF,               # gx = 0xFF80 -> -128 -> -128/131.072 dps
      0x00, 0x00, 0x00, 0x00,   # gy, gz
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00,               # temp
    ].pack("C*")
    @i2c.queue_read(payload)

    snap = @imu.snapshot

    assert_in_delta(-1.0, snap[:accel][:x], 1e-6)
    assert_in_delta(-128.0 / 131.072, snap[:gyro][:x], 1e-6)
  end
end

class BMI270NarrowReadTest < Test::Unit::TestCase
  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @imu = BMI270.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_acceleration_reads_6_bytes_at_acc_x_lsb
    @i2c.queue_read([0x00, 0x40, 0x00, 0x00, 0x00, 0x00].pack("C*"))
    a = @imu.acceleration
    r = @i2c.reads.first
    assert_equal 0x0C, r[:reg]
    assert_equal 6, r[:length]
    assert_in_delta 1.0, a[:x], 1e-6
  end

  def test_gyroscope_reads_6_bytes_at_gyr_x_lsb
    @i2c.queue_read([0x00, 0x00, 0x00, 0x00, 0x00, 0x00].pack("C*"))
    @imu.gyroscope
    r = @i2c.reads.first
    assert_equal 0x12, r[:reg]
    assert_equal 6, r[:length]
  end

  def test_temperature_reads_2_bytes_at_temperature_lsb
    # raw = 0x0100 = 256 -> 256/512 + 23 = 23.5 C
    @i2c.queue_read([0x00, 0x01].pack("C*"))
    t = @imu.temperature
    r = @i2c.reads.first
    assert_equal 0x22, r[:reg]
    assert_equal 2, r[:length]
    assert_in_delta 23.5, t, 1e-6
  end
end

class BMI270RangeTest < Test::Unit::TestCase
  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @imu = BMI270.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_accel_range_writes_acc_range_register_and_updates_scale
    @imu.accel_range = BMI270::ACCEL_RANGE_16G
    w = @i2c.writes.first
    assert_equal 0x41, w[:args][0], "accel range must write REG_ACC_RANGE"
    assert_equal BMI270::ACCEL_RANGE_16G, w[:args][1]

    # At +/-16G the scale is 2048; a raw of 2048 must read as 1.0g.
    @i2c.reads.clear
    @i2c.queue_read([0x00, 0x08, 0x00, 0x00, 0x00, 0x00].pack("C*")) # 0x0800 = 2048
    assert_in_delta 1.0, @imu.acceleration[:x], 1e-6
  end

  def test_gyro_range_writes_gyr_range_register_and_updates_scale
    @imu.gyro_range = BMI270::GYRO_RANGE_2000DPS
    w = @i2c.writes.first
    assert_equal 0x43, w[:args][0], "gyro range must write REG_GYR_RANGE"
    assert_equal BMI270::GYRO_RANGE_2000DPS, w[:args][1]

    # At +/-2000dps the scale is 16.384; raw 16384 -> 1000 dps.
    @i2c.reads.clear
    @i2c.queue_read([0x00, 0x40, 0x00, 0x00, 0x00, 0x00].pack("C*")) # 0x4000 = 16384
    assert_in_delta 1000.0, @imu.gyroscope[:x], 1e-3
  end
end

class BMI270ReadAllBurstTest < Test::Unit::TestCase
  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @imu = BMI270.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_read_all_uses_single_24_byte_burst
    @i2c.queue_read(("\x00".b * 24))

    result = @imu.read_all

    assert_equal 1, @i2c.reads.size,
      "read_all must do exactly one I2C transaction"
    assert_equal 24, @i2c.reads.first[:length]
    assert_equal 0x0C, @i2c.reads.first[:reg]

    assert_kind_of Hash, result
    assert_kind_of Hash, result[:accel]
    assert result[:accel].key?(:x)
    assert result[:accel].key?(:y)
    assert result[:accel].key?(:z)
    assert_kind_of Hash, result[:gyro]
    assert_kind_of Float, result[:temp]
  end
end

class BMI270TickSamplerTest < Test::Unit::TestCase
  ZERO24 = ("\x00".b * 24).freeze
  ONEG24 = ([0x00, 0x40] + [0x00] * 22).pack("C*").freeze

  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @imu = BMI270.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_fresh_is_false_before_first_sample
    assert_equal false, @imu.fresh?
  end

  def test_latest_accessors_are_nil_before_first_sample
    assert_nil @imu.latest_snapshot
    assert_nil @imu.latest_acceleration
    assert_nil @imu.latest_gyroscope
    assert_nil @imu.latest_temperature
  end

  def test_first_tick_always_samples
    @i2c.queue_read(ONEG24)
    sampled = @imu.tick(1000)
    assert_equal true, sampled
    assert_equal true, @imu.fresh?
    assert_in_delta 1.0, @imu.latest_acceleration[:x], 1e-6
    assert_equal 1, @i2c.reads.size
  end

  def test_tick_within_interval_is_noop
    @i2c.queue_read(ZERO24)
    assert_equal true, @imu.tick(1000)
    assert_equal false, @imu.tick(1010)
    assert_equal 1, @i2c.reads.size, "no second I2C read should fire inside the interval"
  end

  def test_tick_after_interval_samples_again
    @i2c.queue_read(ZERO24)
    @i2c.queue_read(ONEG24)
    @imu.tick(1000)
    sampled = @imu.tick(1025)
    assert_equal true, sampled
    assert_equal 2, @i2c.reads.size
    assert_in_delta 1.0, @imu.latest_acceleration[:x], 1e-6
  end

  def test_configure_sampling_changes_interval
    @imu.configure_sampling(interval_ms: 100)
    @i2c.queue_read(ZERO24)
    @i2c.queue_read(ZERO24)
    @imu.tick(0)
    assert_equal false, @imu.tick(50),  "still within new 100ms interval"
    assert_equal true,  @imu.tick(150), "now beyond 100ms interval"
  end

  def test_latest_accessors_return_cached_values
    @i2c.queue_read(ONEG24)
    @imu.tick(1000)
    a = @imu.latest_acceleration
    g = @imu.latest_gyroscope
    t = @imu.latest_temperature
    assert_in_delta 1.0,  a[:x], 1e-6
    assert_in_delta 0.0,  g[:x], 1e-6
    assert_in_delta 23.0, t, 1e-6
  end
end

class BMI270MotionAnalysisTest < Test::Unit::TestCase
  def setup
    @i2c = FakeI2C.new
    queue_init_reads(@i2c)
    @imu = BMI270.new(@i2c)
    @i2c.writes.clear
    @i2c.reads.clear
  end

  def test_magnitude_of_1g_on_z_is_1
    # az = 1g, others 0
    @i2c.queue_read([0x00, 0x00, 0x00, 0x00, 0x00, 0x40].pack("C*"))
    assert_in_delta 1.0, @imu.magnitude, 1e-6
  end

  def test_tilt_angles_flat_is_zero
    # az = 1g (flat), ax = ay = 0
    @i2c.queue_read([0x00, 0x00, 0x00, 0x00, 0x00, 0x40].pack("C*"))
    tilt = @imu.tilt_angles
    assert_in_delta 0.0, tilt[:pitch], 1e-6
    assert_in_delta 0.0, tilt[:roll], 1e-6
  end
end
