Airbrake.configure do |config|
  config.api_key = '2428844a446ec454b6cca44b4f84c3cd'
  config.host    = 'errbit'
  config.port    = 80
  config.secure  = config.port == 443
end
