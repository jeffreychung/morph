require 'resque/server'
require 'resque/failure/multiple'
require 'resque/failure/airbrake'
require 'resque/failure/redis'

resque_config = YAML.load_file(Rails.root + 'config/resque.yml')[Rails.env].symbolize_keys
Resque.redis = Redis.new(resque_config)

Resque::Failure::Multiple.classes = [Resque::Failure::Redis, Resque::Failure::Airbrake]
Resque::Failure.backend = Resque::Failure::Multiple
