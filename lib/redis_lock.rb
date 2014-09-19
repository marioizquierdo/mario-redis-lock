require "redis_lock/version"

class RedisHerdLock

  def self.config_defaults(opts={})
    # ...
  end

  def self.acquire(opts={}, &block)
    # ...
  end

  def initialize(opts={})
    # ...
  end

  def acquire(opts={}, &block)
    # ...
  end

  def release
    # ...
  end
end
