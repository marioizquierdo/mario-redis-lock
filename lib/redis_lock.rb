require 'redis' # redis gem required
require 'ostruct' # OpenStruct (from stdlib)
require 'securerandom' # SecureRandom (from stdlib)

class RedisLock

  VERSION = "0.0.1"

  @@defaults = OpenStruct.new({
    redis: nil, # Redis instance with defaults
    key: 'RedisLock::default', # Redis key to store the lock
    autorelease: 10.0, # seconds to expire
    retry: true, # false to only try to acquire once
    retry_timeout: 10.0, # max number of seconds to keep doing retries if the lock is not available
    retry_sleep: 0.1 # seconds to sleep before the nex retry
  })

  @@defaults.to_h.keys.each do |attr|
    attr_accessor attr
  end
  attr_accessor :acquired_token # if the lock was successfully acquired, this is the token used to identify the lock. False otherwise.
  attr_accessor :last_acquire_retries # info about how many times had to retry to acquire the lock on the last call to acquire. First try counts as 0

  # Configure default values
  def self.configure
    yield @@defaults
  end

  # Acquire a lock. Use options to override defaults.
  # This method makes sure to release the lock as soon as the block is finalized.
  def self.acquire(opts={}, &block)
    lock = RedisLock.new(opts)
    if lock.acquire
      begin
        block.call(lock)
      ensure
        lock.release
      end
    else
      block.call(lock)
    end
  end

  def initialize(opts={})
    # Check if options are valid
    allowed_opts = @@defaults.to_h.keys
    invalid_opts = opts.keys - allowed_opts
    raise ArgumentError("Invalid options: #{invalid_opts.inspect}. Please use one of #{allowed_opts.inspect} ") unless invalid_opts.empty?

    # Set attributes from options or defaults
    self.redis = opts[:redis] || @@defaults.redis || Redis.new
    self.redis = Redis.new(redis) if redis.is_a? Hash # allow to use Redis options instead of a redis instance
    self.key           = opts[:key] || @@defaults.key
    self.autorelease   = opts[:autorelease] || @@defaults.autorelease
    self.retry         = opts.include?(:retry) ? opts[:retry] : @@defaults.retry
    self.retry_timeout = opts[:retry_timeout] || @@defaults.retry_timeout
    self.retry_sleep   = opts[:retry_sleep] || @@defaults.retry_sleep
  end

  # Try to acquire the lock.
  # Retrun true on success, false on failure (someone else has the lock)
  def acquire
    @first_try_time ||= Time.now
    @token ||= "#{@first_try_time}-#{rand 999999}" # token is used to make sure that we own the lock when releasing it
    @retries ||= 0

    # Lock using a redis key, if not exists (NX) with an expiration time (EX).
    # NOTE that the NX and EX options are not supported by REDIS versions older than 2.6.12
    # See lock pattern: http://redis.io/commands/SET
    if redis.set(key, @token, nx: true, ex: autorelease)
      self.acquired_token = @token # assign acquired_token

    else
      self.acquired_token = nil # clear acquired_token, to make the acquired? method return false

      # Wait and try again if retry option is set and didn't timeout
      if self.retry and (Time.now - @first_try_time) < retry_timeout
        sleep retry_sleep # wait
        @retries += 1
        return acquire # and try again
      end
    end

    self.last_acquire_retries = @retries
    @retries = nil # reset retries
    @first_try_time = nil # reset timestamp

    return self.acquired?
  end

  # Release the lock.
  # Returns a Symbol with the status of the operation:
  #   * :success if properly released
  #   * :already_released if the lock was already released or expired (other process could be using it now)
  #   * :not_acquired if the lock was not acquired (no release action was made because it was not needed)
  def release
    if acquired?
      script = 'if redis.call("get",KEYS[1]) == ARGV[1] then return redis.call("del",KEYS[1]) else return nil end'
      ret = redis.eval(script, [key], [self.acquired_token])
      if ret == nil
        :already_released
      else
        :success
      end
    else
      :not_acquired
    end
  end

  # Check if last lock acquisition was successful.
  # Note that it doesn't track autorelease, if the lock is naturally expired, this value will still be true.
  def acquired?
    !!self.acquired_token # acquired_token is only set on success
  end
end
