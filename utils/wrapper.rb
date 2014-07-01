require 'json'
require 'turbot_runner'

# Flush output immediately
STDOUT.sync = true
STDERR.sync = true

class Runner < TurbotRunner::BaseRunner
  def handle_valid_record(record, data_type)
    record[:data_type] = data_type
    STDOUT.puts(record.to_json)
  end

  def handle_failed_run
    STDERR.puts('Bot did not run to completion')
  end
end

runner = Runner.new('/repo')
runner.run(:validate => false)
