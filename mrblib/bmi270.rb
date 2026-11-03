# BMI270 6-axis inertial sensor - Pure Ruby Implementation
#
# Drop-in compatible with the MPU6886 gem interface: the same public methods,
# signatures and return shapes ({x:, y:, z:} symbol-keyed Hashes) are provided,
# so existing code can switch from MPU6886 to BMI270 by changing the class name.
#
# Unlike the MPU6886, the BMI270 requires an ~8KB configuration firmware to be
# uploaded over I2C during initialization (see bmi270_config.rb) and stores its
# sensor data little-endian.

require 'i2c'

class BMI270
  # BMI270 I2C address (0x68; 0x69 when SDO is tied HIGH)
  I2C_ADDRESS = 0x68

  # Register addresses
  REG_CHIP_ID         = 0x00
  REG_ACC_X_LSB       = 0x0C   # accel data start (LSB first)
  REG_GYR_X_LSB       = 0x12   # gyro data start (LSB first)
  REG_TEMPERATURE_LSB = 0x22   # temperature (LSB first)
  REG_INTERNAL_STATUS = 0x21
  REG_ACC_CONF        = 0x40
  REG_ACC_RANGE       = 0x41
  REG_GYR_CONF        = 0x42
  REG_GYR_RANGE       = 0x43
  REG_INIT_CTRL       = 0x59
  REG_INIT_ADDR_0     = 0x5B
  REG_INIT_ADDR_1     = 0x5C
  REG_INIT_DATA       = 0x5E
  REG_PWR_CONF        = 0x7C
  REG_PWR_CTRL        = 0x7D
  REG_CMD             = 0x7E

  # Chip ID
  CHIP_ID = 0x24

  # Command values
  CMD_SOFTRESET = 0xB6

  # Accelerometer range settings (ACC_RANGE register encoding)
  ACCEL_RANGE_2G  = 0x00
  ACCEL_RANGE_4G  = 0x01
  ACCEL_RANGE_8G  = 0x02
  ACCEL_RANGE_16G = 0x03

  # Gyroscope range settings (GYR_RANGE register encoding).
  # Note: the register encoding is the reverse of the MPU6886's, but the
  # public constant names match for interface compatibility. GYRO_RANGE_125DPS
  # is BMI270-specific (no MPU6886 equivalent).
  GYRO_RANGE_2000DPS = 0x00
  GYRO_RANGE_1000DPS = 0x01
  GYRO_RANGE_500DPS  = 0x02
  GYRO_RANGE_250DPS  = 0x03
  GYRO_RANGE_125DPS  = 0x04

  # Scale values (LSB per unit; changed by range).
  # Accel: 32768 / full_scale_g. Gyro: 32768 / full_scale_dps.
  ACCEL_SCALES = {
    ACCEL_RANGE_2G  => 16384.0,
    ACCEL_RANGE_4G  => 8192.0,
    ACCEL_RANGE_8G  => 4096.0,
    ACCEL_RANGE_16G => 2048.0
  }

  GYRO_SCALES = {
    GYRO_RANGE_2000DPS => 16.384,
    GYRO_RANGE_1000DPS => 32.768,
    GYRO_RANGE_500DPS  => 65.536,
    GYRO_RANGE_250DPS  => 131.072,
    GYRO_RANGE_125DPS  => 262.144
  }

  # Bytes per INIT_DATA burst while uploading the config firmware. Must be even
  # (the internal write address is word-based). Tunable for I2C buffer limits.
  CONFIG_CHUNK_SIZE = 128

  # Default tick / start_sampling interval, used by init_sensor seed and as
  # the configure_sampling kwarg default. Single source of truth.
  DEFAULT_SAMPLER_INTERVAL_MS = 20

  # Initialize
  # @param i2c_instance [I2C] Existing I2C instance
  def initialize(i2c_instance)
    @i2c = i2c_instance

    @accel_scale = ACCEL_SCALES[ACCEL_RANGE_2G]
    @gyro_scale = GYRO_SCALES[GYRO_RANGE_250DPS]

    init_sensor
  end

  # Get acceleration data (G units)
  # @return [Hash] {x: Float, y: Float, z: Float}
  def acceleration
    data = read_reg(REG_ACC_X_LSB, 6)

    # Convert to 16-bit signed integer (little-endian: LSB first)
    raw_x = to_signed_16bit((data[1] << 8) | data[0])
    raw_y = to_signed_16bit((data[3] << 8) | data[2])
    raw_z = to_signed_16bit((data[5] << 8) | data[4])

    # Convert to G units
    {
      x: raw_x / @accel_scale,
      y: raw_y / @accel_scale,
      z: raw_z / @accel_scale
    }
  end

  # Get gyroscope data (degrees/second)
  # @return [Hash] {x: Float, y: Float, z: Float}
  def gyroscope
    data = read_reg(REG_GYR_X_LSB, 6)

    # Convert to 16-bit signed integer (little-endian: LSB first)
    raw_x = to_signed_16bit((data[1] << 8) | data[0])
    raw_y = to_signed_16bit((data[3] << 8) | data[2])
    raw_z = to_signed_16bit((data[5] << 8) | data[4])

    # Convert to degrees/second
    {
      x: raw_x / @gyro_scale,
      y: raw_y / @gyro_scale,
      z: raw_z / @gyro_scale
    }
  end

  # Get temperature data (Celsius)
  # @return [Float] Temperature (°C)
  def temperature
    data = read_reg(REG_TEMPERATURE_LSB, 2)

    # Convert to 16-bit signed integer (little-endian: LSB first)
    raw_temp = to_signed_16bit((data[1] << 8) | data[0])

    # Convert to Celsius (datasheet formula)
    raw_temp / 512.0 + 23.0
  end

  # Set accelerometer range
  # @param range [Integer] Accelerometer range
  def accel_range=(range)
    write_reg(REG_ACC_RANGE, range)
    @accel_scale = ACCEL_SCALES[range] || ACCEL_SCALES[ACCEL_RANGE_2G]
  end

  # Set gyroscope range
  # @param range [Integer] Gyroscope range
  def gyro_range=(range)
    write_reg(REG_GYR_RANGE, range)
    @gyro_scale = GYRO_SCALES[range] || GYRO_SCALES[GYRO_RANGE_250DPS]
  end

  # Read all sensor data at once via a single I2C burst.
  # Kept as a public-API alias of {#snapshot} for backward compatibility with
  # the MPU6886 interface.
  # @return [Hash] {accel: Hash, gyro: Hash, temp: Float}
  # @see #snapshot
  def read_all
    snapshot
  end

  # Get all sensor data atomically via a single burst read.
  # Reads REG_ACC_X_LSB..REG_TEMPERATURE_MSB (0x0C..0x23) in one transaction:
  # accel (6B) + gyro (6B) + sensortime/status (10B) + temperature (2B).
  # @return [Hash] { accel: {x:, y:, z:}, gyro: {x:, y:, z:}, temp: Float }
  def snapshot
    data = read_reg(REG_ACC_X_LSB, 24)
    raw_ax = to_signed_16bit((data[1] << 8) | data[0])
    raw_ay = to_signed_16bit((data[3] << 8) | data[2])
    raw_az = to_signed_16bit((data[5] << 8) | data[4])
    raw_gx = to_signed_16bit((data[7] << 8) | data[6])
    raw_gy = to_signed_16bit((data[9] << 8) | data[8])
    raw_gz = to_signed_16bit((data[11] << 8) | data[10])
    raw_t  = to_signed_16bit((data[23] << 8) | data[22])

    {
      accel: {
        x: raw_ax / @accel_scale,
        y: raw_ay / @accel_scale,
        z: raw_az / @accel_scale,
      },
      gyro: {
        x: raw_gx / @gyro_scale,
        y: raw_gy / @gyro_scale,
        z: raw_gz / @gyro_scale,
      },
      temp: raw_t / 512.0 + 23.0,
    }
  end

  # Configure the sampling interval for both tick() and start_sampling().
  # @param interval_ms [Integer] minimum milliseconds between successive samples
  def configure_sampling(interval_ms: DEFAULT_SAMPLER_INTERVAL_MS)
    @sampler_interval_ms = interval_ms
  end

  # Cooperative single-loop sampler. Call from your main loop.
  # Performs one snapshot if at least @sampler_interval_ms have elapsed since
  # the last sample (or no sample has been taken yet); otherwise no-op.
  # @param now_ms [Integer, nil] current monotonic millisecond count.
  #   Pass nil to use Machine.uptime_us / 1000 if available, else 0.
  # @return [Boolean] true if a fresh sample was taken
  def tick(now_ms = nil)
    now_ms = _now_ms if now_ms.nil?
    if !@latest.nil? && (now_ms - @latest_at_ms) < @sampler_interval_ms
      return false
    end
    @latest = snapshot
    @latest_at_ms = now_ms
    true
  end

  # @return [Boolean] true once at least one sample has been cached
  def fresh?
    !@latest.nil?
  end

  # @return [Hash, nil] the most recent full snapshot, or nil if never sampled
  def latest_snapshot
    @latest
  end

  # @return [Hash, nil] {x:, y:, z:} from the latest snapshot, or nil
  def latest_acceleration
    @latest && @latest[:accel]
  end

  # @return [Hash, nil] {x:, y:, z:} from the latest snapshot, or nil
  def latest_gyroscope
    @latest && @latest[:gyro]
  end

  # @return [Float, nil] temperature from the latest snapshot, or nil
  def latest_temperature
    @latest && @latest[:temp]
  end

  # Calculate combined acceleration
  # @return [Float] Combined acceleration (G units)
  def magnitude
    accel = acceleration
    Math.sqrt(accel[:x] ** 2 + accel[:y] ** 2 + accel[:z] ** 2)
  end

  # Calculate tilt angles (degrees)
  # @return [Hash] {pitch: Float, roll: Float}
  def tilt_angles
    accel = acceleration

    # Pitch angle (around X axis)
    pitch = Math.atan2(accel[:y], Math.sqrt(accel[:x] ** 2 + accel[:z] ** 2)) * 180.0 / Math::PI

    # Roll angle (around Y axis)
    roll = Math.atan2(-accel[:x], Math.sqrt(accel[:y] ** 2 + accel[:z] ** 2)) * 180.0 / Math::PI

    { pitch: pitch, roll: roll }
  end

  # Detect motion (acceleration change)
  # @param threshold [Float] Detection threshold (G units, default 0.1G)
  # @return [Boolean] true if motion detected
  def motion_detected?(threshold = 0.1)
    magnitude > (1.0 + threshold) || magnitude < (1.0 - threshold)
  end

  # Spawn a background Task that calls snapshot every @sampler_interval_ms
  # and updates the cached latest_* values. Idempotent: a second call with an
  # already-running sampler returns the existing Task handle.
  #
  # Dual-engine: mruby/c does not forward blocks to Task#initialize, so we
  # compile a script string and use Task.create. microruby (mruby) accepts a
  # block on Task.new normally.
  #
  # @param interval_ms [Integer] sampling interval in ms (default DEFAULT_SAMPLER_INTERVAL_MS = 50Hz)
  # @return [Task] handle to the running sampler
  def start_sampling(interval_ms: DEFAULT_SAMPLER_INTERVAL_MS)
    return @sampler_task if @sampler_task
    @sampler_interval_ms = interval_ms
    @sampler_running = true
    @latest = nil
    @latest_at_ms = 0
    if RUBY_ENGINE == "mruby/c"
      $__bmi270_sampler_target = self
      mrb = PicoRubyVM::InstructionSequence.compile(
        '$__bmi270_sampler_target._run_sampler_loop'
      ).to_binary
      @sampler_task = Task.create(mrb)
      raise "BMI270: failed to create sampler task" if @sampler_task.nil?
      @sampler_task.run
    else
      imu = self
      @sampler_task = Task.new { imu._run_sampler_loop }
    end
    @sampler_task
  end

  # Halt the background sampler and clear the Task handle.
  # Safe to call when no sampler is running.
  def stop_sampling
    return unless @sampler_task
    @sampler_running = false
    @sampler_task.join
    @sampler_task = nil
  end

  # Body of the background sampler Task. Public-by-necessity because
  # the spawned Task script and the block both invoke it.
  # DO NOT call directly: this loops until @sampler_running is set false
  # externally. Use start_sampling / stop_sampling.
  #
  # Task.pass is the load-bearing line for the mruby/c scheduler; without an
  # explicit yield the main task does not get room to run between iterations.
  def _run_sampler_loop
    interval_ms = @sampler_interval_ms
    while @sampler_running
      @latest = snapshot
      Task.pass
      sleep_ms(interval_ms)
    end
  end

  # Monotonic millisecond clock. Calls Machine.uptime_us directly; on host
  # the test harness stubs Machine. Only callable from the main task context.
  def _now_ms
    Machine.uptime_us / 1000
  end

  private

  # Initialize sensor: verify chip ID, upload config firmware, enable sensors.
  def init_sensor
    # Sampler state seeds (must precede any read; tick/start_sampling rely on them)
    @latest = nil
    @latest_at_ms = 0
    @sampler_interval_ms = DEFAULT_SAMPLER_INTERVAL_MS
    @sampler_task = nil
    @sampler_running = false

    # Check chip ID
    chip_id = read_reg(REG_CHIP_ID, 1)[0]
    raise "Invalid BMI270 chip ID: 0x#{chip_id.to_s(16)} (expected: 0x#{CHIP_ID.to_s(16)})" unless chip_id == CHIP_ID

    # Soft reset, then wait for the device to settle
    write_reg(REG_CMD, CMD_SOFTRESET)
    sleep_ms 5

    # Disable advanced power save before uploading the config firmware
    write_reg(REG_PWR_CONF, 0x00)
    sleep_ms 1

    # Upload initialization firmware
    write_reg(REG_INIT_CTRL, 0x00)
    load_config_file
    write_reg(REG_INIT_CTRL, 0x01)
    wait_for_init

    # Enable temperature, gyroscope and accelerometer
    write_reg(REG_PWR_CTRL, 0x0E)
    sleep_ms 5

    # Performance mode: 100Hz accel, 200Hz gyro, power save off
    write_reg(REG_ACC_CONF, 0xA8)
    write_reg(REG_GYR_CONF, 0xA9)
    write_reg(REG_PWR_CONF, 0x02)

    # Default settings (match MPU6886 defaults)
    self.accel_range = ACCEL_RANGE_2G
    self.gyro_range = GYRO_RANGE_250DPS

    sleep_ms 10
  end

  # Upload the config firmware to the device, chunk by chunk.
  # Each chunk is preceded by the word-based internal write address.
  def load_config_file
    config = CONFIG_FILE
    size = config.bytesize
    offset = 0
    while offset < size
      chunk = config[offset, CONFIG_CHUNK_SIZE]
      word = offset / 2
      write_reg(REG_INIT_ADDR_0, word & 0x0F)
      write_reg(REG_INIT_ADDR_1, (word >> 4) & 0xFF)
      result = @i2c.write(I2C_ADDRESS, REG_INIT_DATA, chunk, timeout: 2000)
      unless result > 0
        raise IOError, "BMI270 config upload failed (offset: #{offset})"
      end
      offset += CONFIG_CHUNK_SIZE
    end
  end

  # Poll INTERNAL_STATUS until the config load reports init_ok (0x01).
  def wait_for_init
    50.times do
      status = read_reg(REG_INTERNAL_STATUS, 1)[0]
      return if (status & 0x0F) == 0x01
      sleep_ms 10
    end
    raise "BMI270 init failed: INTERNAL_STATUS did not reach init_ok (0x01)"
  end

  # Write to register
  # @param reg [Integer] Register address
  # @param data [Integer] Data to write
  def write_reg(reg, data)
    result = @i2c.write(I2C_ADDRESS, reg, data, timeout: 2000)
    unless result > 0
      raise IOError, "BMI270 write failed (reg: 0x#{reg.to_s(16)}, data: 0x#{data.to_s(16)})"
    end
  end

  # Read from register
  # @param reg [Integer] Register address
  # @param length [Integer] Number of bytes to read
  # @return [Array<Integer>] Array of read data
  def read_reg(reg, length)
    data = @i2c.read(I2C_ADDRESS, length, reg, timeout: 1000)

    if data.nil? || data.empty?
      raise IOError, "BMI270 read failed (reg: 0x#{reg.to_s(16)}, length: #{length})"
    end

    # Convert from String to byte array
    data.bytes
  end

  # Convert 16-bit value to signed integer
  # @param value [Integer] Unsigned 16-bit value
  # @return [Integer] Signed 16-bit value
  def to_signed_16bit(value)
    value > 32767 ? value - 65536 : value
  end
end
