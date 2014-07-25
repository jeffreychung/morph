require 'json'
require 'json-schema'
require 'turbot_runner'

# Flush output immediately
STDOUT.sync = true
STDERR.sync = true

MAX_DRAFT_ROWS = 2000

class Runner < TurbotRunner::BaseRunner
  def initialize(*)
    super
    @count = 0
  end

  def handle_valid_record(record, data_type)
    if ENV['RUN_TYPE'] == "draft" && @count > MAX_DRAFT_ROWS
      sleep 5 # allow some time for OS to flush buffers
      interrupt
    else
      record[:data_type] = data_type
      STDOUT.puts(record.to_json)
      @count += 1
    end
  end

  def handle_invalid_record(record, data_type, errors)
    STDERR.puts
    STDERR.puts "The following record is invalid:"
    STDERR.puts record.to_json
    errors.each {|error| STDERR.puts " * #{error}"}
    STDERR.puts

    handle_failed_run
    interrupt
  end

  def handle_failed_run
    # This string is important.  We check for its presence in runner.rb to
    # determine whether the run was successful.  It would be much better if we
    # could check the return code of this script, but docker does not reliably
    # pick up the return code, so we've got to improvise.
    STDERR.puts(@error)
  end
end

runner = Runner.new('/repo')
runner.run

# It'd be nice if this worked, but it doesn't.  See note above.
#if runner.successful?
#  exit(0)
#else
#  exit(1)
#end
