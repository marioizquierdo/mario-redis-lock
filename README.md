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
RedisLock.adquire do |lock|
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

The class method `RedisLock.adquire(options, &block)` is more concise and releases the lock at the end of the block, even if `do_exclusive_stuff` raises an exception.
But the second alternative is a little more flexible.


### Options

  * **redis**: (default `Redis.new`) an instance of Redis, or an options hash to initialize an instance of Redis (see [redis gem](https://rubygems.org/gems/redis)). You can also pass anything that "quaks" like redis, for example an instance of [mock_redis](https://rubygems.org/gems/mock_redis), for testing purposes.
  * **key**: (default `"RedisLock::default"`) Redis key used for the lock. If you need multiple locks, use a different (unique) key for each lock.
  * **autorelease**: (default `10.0`) seconds to automatically release (expire) the lock after being acquired. Make sure to give enough time for your "exclusive stuff" to be executed, otherwise other processes could get the lock and start messing with the "exclusive stuff" before this one is done. The autorelease time is important, even when manually doing `lock.realease`, because the process could crash before releasing the lock. Autorelease (expiration time) guarantees that the lock will always be released.
  * **retry**: (default `true`) boolean to enable/disable consecutive acquire retries in the same `acquire` call. If true, use `retry_timeout` and `retry_sleep` to specify how long and hot often should the `acquire` method be blocking the thread until is able to get the lock.
  * **retry_timeout**: (default `10.0`) time in seconds to specify how long should this thread be waiting for the lock to be released. Note that the execution thread is put to sleep while waiting. For a non-blocking approach, set `retry` to false.
  * **retry_sleep**: (default `0.1`) seconds to sleep between retries. For example: `RedisLock.adquire(retry_timeout: 10.0, retry_sleep: 0.1) do |lock|`, in the worst case scenario, will do 99 or 100 retries (one every 100 milliseconds, plus a little extra for the acquire attempt) during 10 seconds, and finally yield with `lock.acquired? == false`.

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

### Example: Shared Photo Booth that can only take one photo at a time

If we have a `PhotoBooth` shared resource, we can use a `RedisLock` to ensure it is used only by one thread at a time:

```ruby
require 'redis_lock'
require 'photo_booth' # made up shared resource

RedisLock.configure do |c|
  c.redis = {url: "redis://:p4ssw0rd@10.0.1.1:6380/15"}
  c.key   = 'photo_booth_lock'

  c.autorelease   = 60 # assume it never takes more than one minute to make a picture
  c.retry_timeout = 300 # retry for 5 minutes
  c.retry_sleep   = 1   # retry once every second
end

RedisLock.acquire do |lock|
  if lock.acquired?
    PhotoBooth.take_photo
  else
    raise "I'm bored of waiting and I'm getting out"
  end
end
```

This script can be executed from many different places at the same time, as far as they have access to the shared PhotoBooth and Redis instances. Only one photo will be taken at a time.
Note that the options `autorelease`, `retry_timeout` and `retry_sleep` should be tuned differently depending on the frequency of the operation and the known speed of the `PhotoBooth.take_photo` operation.


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
  val = redis.get(key)
  if not val
    val = block.call
    redis.setex(key, expire, val) unless val.nil? # do not set anything if the value is nil
  end
  val
end
```

Whith this method, it is easy to optimize slow operations by caching them in Redis.
For example, if you want to do a `heavy_database_query`:

```ruby
require 'redis'
redis = Redis.new(url: "redis://:p4ssw0rd@host:6380")

val = fetch redis, 'heavy_query', 10 do
  heavy_database_query # Recalculate if not cached (SLOW)
end

puts val
```

But this fetch could block the database if executed from too many threads, because when the Redis key expires all of them will do the `heavy_database_query` at the same time.

Avoid this problem with a `RedisLock`:

```ruby
require 'redis'
require 'redis_lock'
redis = Redis.new(url: "redis://:p4ssw0rd@host:6380")

RedisLock.configure do |c|
  c.redis = redis
  c.key = 'heavy_query_lock'
  c.autorelease = 20 # assume it never takes more than 20 seconds to do the slow query
  c.retry = false # try to acquire only once, if the lock is already taken then the new value should be cached again soon
end

def fetch_with_lock(retries = 10)
  val = fetch redis, 'heavy_query', 10 do
    # If we need to recalculate val,
    # use a lock to make sure that heavy_database_query is only done by one process
    RedisLock.acquire do |lock|
      if lock.acquired?
        heavy_database_query
      else
        nil # do not store in cache and return val = nil
      end
    end
  end

  # Try again if cache miss, and the lock was acquired by other process.
  if val.nil? and retries > 0
    fetch_with_lock(retries - 1)
  else
    val
  end
end

val = fetch_with_lock()
puts val
```

In this case, the script could be executed from as many threads as we want at the same time, because the heavy_database_query is done only once while the other threads wait until the value is cached again or the lock is released.


## Contributing

1. Fork it ( http://github.com/marioizquierdo/redis-lock/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

Make sure you have installed Redis in localhost:6379. The DB 15 will be used for tests (and flushed after every test).
There is a rake task to play with an example: `rake smoke_and_pass`
