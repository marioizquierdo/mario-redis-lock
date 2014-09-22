# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "mario-redis-lock"
  spec.version       = RedisLock::VERSION
  spec.authors       = ["Mario Izquierdo"]
  spec.email         = ["tomario@gmail.com"]
  spec.summary       = %q{Yet another distributed lock for Ruby using Redis.}
  spec.description   = %q{Yet another distributed lock for Ruby using Redis, with emphasis in the documentation. Requires Redis >= 2.6.12, because it uses the new syntax for SET to easily implement the robust algorithm described in the SET command documentation (http://redis.io/commands/set).}
  spec.homepage      = "https://github.com/marioizquierdo/mario-redis-lock"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.5"
  spec.add_development_dependency "rake"
end
