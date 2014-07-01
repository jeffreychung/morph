require 'yaml'

config = YAML.load_file(Rails.root + 'config/hutch.yml')[Rails.env].symbolize_keys
HutchConfig = Hutch::Config
config.each do |k, v|
  HutchConfig.set(k.to_sym, v)
end
HutchConfig.set(:log_level, Logger::WARN)
Hutch::Logging.logger = Rails.logger
