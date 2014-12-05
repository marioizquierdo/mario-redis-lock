# RedisLock

Yet another distributed lock for Ruby using Redis, with emphasis in the documentation.


## Why another redis lock gem?

Other redis locks for ruby: [redis-mutex](https://rubygems.org/gems/redis-mutex), [mlanett-redis-lock](https://rubygems.org/gems/mlanett-redis-lock), [redis-lock](https://rubygems.org/gems/redis-lock), [jashmenn-redis-lock](https://rubygems.org/gems/jashmenn-redis-lock), [ruby_redis_lock](https://rubygems.org/gems/ruby_redis_lock), [robust-redis-lock](https://rubygems.org/gems/robust-redis-lock), [bfg-redis-lock](https://rubygems.org/gems/bfg-redis-lock), etc.

Looking at those other gems I realized that it was not easy to know what was exactly going on with the locks. Then I made this one to be simple but explicit, to be used with confidence in my high scale production applications.


## Installation

Requirements:

  * [Redis](http://redis.io/) >= 2.6.12
  * [redis gem](https://rubygems.org/gems/redis) >= 3.0.5

The required versions are needed for the new syntax of the SET command, to easily implement the robust locking algorithm described in the [SET command documentation](http://redis.io/commands/set).

Install from RubyGems:

    $ gem install mario-redis-lock

Or include it in your project's `Gemfile` with Bundler:

    gem 'mario-redis-lock', :require => 'redis_lock'


## Usage

Acquire the lock to do "exclusive stuff":

```ruby
RedisLock.acquire do |lock|
  if lock.acquired?
    do_exclusive_stuff # you are the one with the lock, hooray!
  else
    oh_well # someone else has the lock
  end
end
```

Or (equivalent)


```ruby
lock = RedisLock.new
if lock.acquire
  begin
    do_exclusive_stuff # you are the one with the lock, hooray!
  ensure
    lock.release
  end
else
  oh_well # someone else has the lock
end
```

The class method `RedisLock.acquire(options, &block)` is more concise and releases the lock at the end of the block, even if `do_exclusive_stuff` raises an exception.
But the second alternative is a little more flexible.


### Options

  * **redis**: (default `Redis.new`) an instance of Redis, or an options hash to initialize an instance of Redis (see [redis gem](https://rubygems.org/gems/redis)). You can also pass anything that "quaks" like redis, for example an instance of [mock_redis](https://rubygems.org/gems/mock_redis), for testing purposes.
  * **key**: (default `"RedisLock::default"`) Redis key used for the lock. If you need multiple locks, use a different (unique) key for each lock.
  * **autorelease**: (default `10.0`) seconds to automatically release (expire) the lock after being acquired. Make sure to give enough time for your "exclusive stuff" to be executed, otherwise other processes could get the lock and start messing with the "exclusive stuff" before this one is done. The autorelease time is important, even when manually doing `lock.realease`, because the process could crash before releasing the lock. Autorelease (expiration time) guarantees that the lock will always be released.
  * **retry**: (default `true`) boolean to enable/disable consecutive acquire retries in the same `acquire` call. If true, use `retry_timeout` and `retry_sleep` to specify how long and hot often should the `acquire` method be blocking the thread until is able to get the lock.
  * **retry_timeout**: (default `10.0`) time in seconds to specify how long should this thread be waiting for the lock to be released. Note that the execution thread is put to sleep while waiting. For a non-blocking approach, set `retry` to false.
  * **retry_sleep**: (default `0.1`) seconds to sleep between retries. For example: `RedisLock.acquire(retry_timeout: 10.0, retry_sleep: 0.1) do |lock|`, in the worst case scenario, will do 99 or 100 retries (one every 100 milliseconds, plus a little extra for the acquire attempt) during 10 seconds, and finally yield with `lock.acquired? == false`.

Configure the default values with `RedisLock.configure`:

```ruby
RedisLock.configure do |defaults|
  defaults.redis = Redis.new
  defaults.key = "RedisLock::default"
  defaults.autorelease = 10.0
  defaults.retry = true
  defaults.retry_timeout = 10.0
  defaults.retry_sleep = 0.1
end
```

A good place to set defaults in a Rails app would be in an initializer `conf/initializers/redis_lock.rb`.

Options can be set to other than the defaults when calling `RedisLock.acquire`:

```ruby
RedisLock.acquire(key: 'exclusive_stuff', retry: false) do |lock|
  if lock.acquired?
    do_exclusive_stuff
  end
end
```

Or when creating a new lock instance:

```ruby
lock = RedisLock.new(key: 'exclusive_stuff', retry: false)
if lock.acquire
  begin
    do_exclusive_stuff
  ensure
    lock.release
  end
end
```

### Example: Everybody wants a drink but there is only one waiter

This example can be copy-pasted, just make sure you have redis in localhost and the mario-redis-lock gem installed.

```ruby
require 'redis_lock'

N = 15 # how many people is in the bar
puts "Starting ... #{N} new thirsty customers want to drink ..."
puts

RedisLock.configure do |conf|
  conf.retry_sleep = 1    # call the waiter every second
  conf.retry_timeout = 10 # wait up to 10 seconds before giving up
  conf.autorelease = 3    # if someone can not be serverd in 3 seconds, assume is dead and go to next customer
end

# Code for a single Thread#i
def try_to_get_a_drink(i)
  name = "Thread##{i}"
  RedisLock.acquire do |lock|
    if lock.acquired?
      puts "<< #{name} gets barman's attention (lock acquired)"
      sleep 0.2 # time do decide
      drink = %w(water soda beer wine wiskey)[rand 5]
      puts ".. #{name} decides to drink #{drink}"
      sleep 0.4 # time for the waiter to serve the drink
      puts ">> #{name} has the #{drink} and leaves happy"
      puts
    else
      puts "!! #{name} is bored of waiting and leaves angry (timeout)"
    end
  end
end

# Start N threads that will be executed in parallel
threads = []
N.times(){|i| threads << Thread.new(){ try_to_get_a_drink(i) }}
threads.each{|thread| thread.join} # do not exit until all threads are done

puts "DONE"
```

It uses threads for concurrency, but you can also execute this script from different places at the same time in parallel, they will all be in sync as far as they use the same redis instance.


### Example: Avoid the Dog-Pile effec when invalidating some cached value

The Dog-Pile effect is a specific case of the [Thundering Herd problem](http://en.wikipedia.org/wiki/Thundering_herd_problem),
that happens when a cached value expires and suddenly too many threads try to calculate the new value at the same time.

Sometimes, the calculation takes expensive resources and it is just fine to do it from just one thread.

Assume you have a simple cache, a `fetch` function that uses a redis instance.

Without the lock:

```ruby
# Retrieve the cached value from the redis key.
# If the key is not available, execute the block
# and store the new calculated value in the redis key with an expiration time.
def fetch(redis, key, expire, &block)
  redis.get(key) or (
    val = block.call
    redis.setex(key, expire, val) if val
    val
  )
end
```

Whith this method, it is easy to optimize slow operations by caching them in Redis.
For example, if you want to do a `heavy_database_query`:

```ruby
require 'redis'
redis = Redis.new(url: "redis://:p4ssw0rd@host:6380")
expire = 60 # keep the result cached for 1 minute
key = 'heavy_query'

val = fetch redis, key, expire do
  heavy_database_query # Recalculate if not cached (SLOW)
end

puts val
```

But this fetch could block the database if executed from too many threads, because when the Redis key expires all of them will do the same "heavy_database_query" at the same time.

To avoid this problem, you can make a `fetch_with_lock` method using a `RedisLock`:

```ruby
# Retrieve the cached value from the redis key.
# If the key is not available, execute the block
# and store the new calculated value in the redis key with an expiration time.
# The block is executed with a RedisLock to avoid the dog pile effect.
# Use the following options:
#   * :retry_timeout => (default 10) Seconds to stop trying to get the value from redis or the lock.
#   * :retry_sleep => (default 0.1) Seconds to sleep (block the process) between retries.
#   * :lock_autorelease => (default same as :retry_timeout) Maximum time in seconds to execute the block. The lock is released after this, assuming that the process failed.
#   * :lock_key => (default "#{key}_lock") The key used for the lock.
def fetch_with_lock(redis, key, expire, opts={}, &block)
  # Options
  opts[:retry_timeout] ||= 10
  opts[:retry_sleep] ||= 0.1
  opts[:first_try_time] ||= Time.now # used as memory for next retries
  opts[:lock_key] ||= "#{key}_lock"
  opts[:lock_autorelease] ||= opts[:retry_timeout]

  # Try to get from redis.
  val = redis.get(key)
  return val if val

  # If not in redis, calculate the new value (block.call), but with a RedisLock.
  RedisLock.acquire({
    redis: redis,
    key: opts[:lock_key],
    autorelease: opts[:lock_autorelease],
    retry: false,
  }) do |lock|
    if lock.acquired?
      val = block.call # execute block, load/calculate heavy stuff
      redis.setex(key, expire, val) if val # store in the redis cache
    end
  end
  return val if val

  # If the lock was not available, then someone else was already re-calculating the value.
  # Just wait a little bit and try again.
  if (Time.now - opts[:first_try_time]) < opts[:retry_timeout] # unless timed out
    sleep opts[:retry_sleep]
    return fetch_with_lock(redis, key, expire, opts, &block)
  end

  # If the lock is still unavailable after the timeout, desist and return nil.
  nil
end

```

Now with this new method, is easy to do the "heavy_database_query", cached in redis and with a lock:


```ruby
require 'redis'
require 'redis_lock'
redis = Redis.new(url: "redis://:p4ssw0rd@host:6380")
expire = 60 # keep the result cached for 1 minute
key = 'heavy_query'

val = fetch_with_lock redis, key, expire, retry_timeout: 10, retry_sleep: 1 do
  heavy_database_query # Recalculate if not cached (SLOW)
end

puts val
```

In this case, the script could be executed from as many threads as we want at the same time, because the "heavy_database_query" is done only once while the other threads wait until the value is cached again or the lock is released.

## Contributing

1. Fork it ( http://github.com/marioizquierdo/redis-lock/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

Make sure you have installed Redis in localhost:6379. The DB 15 will be used for tests (and flushed after every test).
There is a rake task to play with an example: `rake smoke_and_pass`
