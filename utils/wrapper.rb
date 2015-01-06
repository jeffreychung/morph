require 'turbot_runner'

# Flush output immediately
STDOUT.sync = true
STDERR.sync = true

MAX_DRAFT_ROWS = 2000

class Handler < TurbotRunner::BaseHandler
  def initialize
    super
    @count = 0
  end

  def handle_valid_record(record, data_type)
    if data_type == 'primary data'
      if ENV['RUN_TYPE'] == "draft" && @count > MAX_DRAFT_ROWS
        raise TurbotRunner::InterruptRun
      else
        @count += 1
      end

      STDOUT.puts "#{Time.now} :: Handled #{@count} records" if @count % 1000 == 0
    end
  end

  def handle_invalid_record(record, data_type, errors)
    STDERR.puts
    STDERR.puts "The following record is invalid:"
    STDERR.puts record.to_json
    errors.each {|error| STDERR.puts " * #{error}"}
    STDERR.puts
  end

  def handle_invalid_json(line)
    STDERR.puts
    STDERR.puts "The following line is invalid JSON:"
    STDERR.puts line
  end
end

runner = TurbotRunner::Runner.new(
  '/repo',
  :log_to_file => true,
  :record_handler => Handler.new,
  :output_directory => '/output'
)

rc = runner.run
exit(rc)
