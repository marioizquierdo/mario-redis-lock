# RedisLock (under construction)

***Version 0.0.1 is on the way ...***

Yet another distributed lock for Ruby using Redis, with emphasis in the documentation.

Requires Redis >= 2.6.12, because it uses the new syntax for SET to easily implement the robust algorithm described in the [SET command](http://redis.io/commands/set) documentation.


## Why another redis lock gem?

I found many others doing the same, for example: [redis-mutex](https://rubygems.org/gems/redis-mutex), [mlanett-redis-lock](https://rubygems.org/gems/mlanett-redis-lock), [redis-lock](https://rubygems.org/gems/redis-lock), [jashmenn-redis-lock](https://rubygems.org/gems/jashmenn-redis-lock), [ruby_redis_lock](https://rubygems.org/gems/ruby_redis_lock), [robust-redis-lock](https://rubygems.org/gems/robust-redis-lock), [bfg-redis-lock](https://rubygems.org/gems/bfg-redis-lock), etc.

But I realized it is not easy to know exactly what's going on with those locks. I made this one to be simple, with minimal dependencies and easy to understand.


## Installation

Add this line to your application's Gemfile to install it with `bundle install`:

    gem 'marioizquierdo-redis-lock'

Or install it yourself as:

    $ gem install marioizquierdo-redis-lock


## Usage

Acquire the lock to do "exclusive stuff":

```ruby
RedisLock.adquire do |lock|
  if lock.acquired?
    do_exclusive_stuff
  else
    oh_well
  end
end
```

Or (equivalent)


```ruby
lock = RedisLock.new
if lock.acquire
  begin
    do_exclusive_stuff
  ensure
    lock.release
  end
else
  oh_well
end
```

The class method `RedisLock.adquire(&block)` makes sure that the lock is released at the end of the block, even if `do_exclusive_stuff` raises an exception.
But the second alternative is more flexible.


### Options

  * **redis**: (default `Redis.new`) an instance of Redis, or an options hash to initialize an instance of Redis (see [redis gem](https://rubygems.org/gems/redis)). You can also pass anything that "quaks" like redis, for example an instance of [mock_redis](https://rubygems.org/gems/mock_redis), for testing purposes.
  * **key**: (default `"RedisLock::default"`) Redis key to store info about the lock. If you need multiple locks, use a different (unique) key for each lock.
  * **autorelease**: (default `10.0`) seconds to automatically release the lock after being acquired. Make sure it is long enough to execute do the "exclusive stuff", otherwise other processes could get the lock and start messing with the "exclusive stuff" before this one is done. Note that autorelease time is needed even if you are doing `lock.realease`, because the process could crash before releasing the lock.
  * **retry: (default `true`) boolean to enable/disable multiple acquire retries.
  * **retry_timeout**: (default `10.0`) time in seconds to specify how long should this thread be waiting for the lock to be released. Note that this thread is blocked while waiting. For a non-blocking approach, set `retry` to false.
  * **retry_sleep**: (default `0.1`) seconds to sleep between retries. For example: `RedisLock.adquire(retry_timeout: 10.0, retry_sleep: 0.1) do |lock|`, in the worst case scenario, will do 99 or 100 retries (one every 100 milliseconds, plus a little extra for the acquire attempt) during 10 seconds, and finally yield with `lock.acquired? == false`.

Configure the default values with `RedisLock.configure`:

```ruby
RedisLock.configure do |default|
  default.redis = Redis.new
  default.key = "RedisLock::default"
  default.autorelease = 10.0
  default.retry = true
  default.retry_timeout = 10.0
  default.retry_sleep = 0.1
end
```

A good place to set defaults in a Rails app would be using an initializer `conf/initializers/redis_lock.rb`.

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

Let's assume we have a "PhotoBooth" shared resource that can be used only by one process thread at a time.
We can implement this using with a `RedisLock`:

```ruby
require 'marioizquierdo-redis-lock'
require 'photo_booth' # made up shared resource

RedisLock.configure do |conf|
  conf.redis = {url: "redis://:p4ssw0rd@10.0.1.1:6380/15"}
  conf.key   = 'photo_booth_lock'

  conf.autorelease   = 60 # assume it never takes more than one minute to make a picture
  conf.retry_timeout = 300 # retry for 5 minutes
  conf.retry_sleep   = 1   # retry once every second
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

Assume you have a `fetch` method that uses a redis instance to cache values like this:
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

```
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
require 'marioizquierdo-redis-lock'
redis = Redis.new(url: "redis://:p4ssw0rd@host:6380")

val = nil
tries = 1000
loop do
  val = fetch redis, 'heavy_query', 10 do
    # Use a lock to make sure only one thread makes the heavy_database_query
    RedisLock.acquire({
      redis: redis,
      key: 'heavy_query_lock',
      autorelease: 20 # assume it never takes more than 20 seconds to do the slow query
      retry: false # try to acquire only once, if the lock is already taken then the new value should be cached again soon
    }) do |lock|
      if lock.acquired?
        heavy_database_query # Recalculate if not cached (SLOW, but done only by one process)
      else
        nil # do not store in cache and return val = nil
      end
    end
  end

  tries -= 1
  if val != nil or tries <= 0
    break # we have a value, or we are tired of doing tries

  # If val could not be calculated, keep trying ...
  # The next time the value could be already cached, or the lock could have been released.
  else
    sleep 1
  end
end

puts val
```

In this case, the script could be executed from as many threads as we want at the same time, because the heavy_database_query is done only once while the other threads wait until the value is cached again or the lock is released.


## Contributing

1. Fork it ( http://github.com/marioizquierdo/redis-lock/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
