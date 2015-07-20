require 'turbot_runner'

# Flush output immediately
STDOUT.sync = true
STDERR.sync = true

MAX_DRAFT_ROWS = 2000

class Handler < TurbotRunner::BaseHandler
  def initialize
    super
    @counts = Hash.new(0)
  end

  def handle_valid_record(record, data_type)
    if ENV['RUN_TYPE'] == "draft" && @counts[data_type] > MAX_DRAFT_ROWS
      raise TurbotRunner::InterruptRun
    else
      @counts[data_type] += 1
    end
    STDOUT.puts "#{Time.now} :: Handled #{@counts[data_type]} records" if @counts[data_type] % 1000 == 0
  end

  def handle_invalid_record(record, data_type, error_message)
    STDERR.puts
    STDERR.puts "The following record is invalid:"
    STDERR.puts record.to_json
    STDERR.puts " * #{error_message}"
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
  :output_directory => '/output',
  :scraper_provided => (ENV['RUN_TYPE'] == 'scraper_provided'),
)

rc = runner.run
exit(rc)
