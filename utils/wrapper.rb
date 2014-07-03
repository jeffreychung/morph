require 'json'
#require 'turbot_runner'

# Flush output immediately
STDOUT.sync = true
STDERR.sync = true

module TurbotRunner
  class ScriptError < StandardError; end

  class BaseRunner
    def initialize(bot_directory)
      @bot_directory = bot_directory

      manifest_path = File.join(bot_directory, 'manifest.json')
      raise "Could not find #{manifest_path}" unless File.exist?(manifest_path)

      begin
        @config = JSON.parse(open(manifest_path) {|f| f.read})
      rescue JSON::ParserError
        # TODO provide better error message
        raise "Could not parse #{manifest_path} as JSON"
      end

      @interrupted = false
      @schemas = {}
    end

    def run(opts={})
      validation_required = opts[:validate] || true

      command = "#{interpreter_for(scraper_file)} #{scraper_file}"
      data_type = @config['data_type']

      begin
        run_script_each_line(command) do |line|
          record = JSON.parse(line)
          errors = validate(record, data_type)

          if errors.empty?
            handle_valid_record(record, data_type)

            transformers.each do |transformer|
              file = File.join(@bot_directory, transformer['file'])
              command1 = "#{interpreter_for(file)} #{file}"
              data_type1 = transformer['data_type']

              run_script_each_line(command1, :input => line) do |line1|
                record1 = JSON.parse(line1)

                errors = validate(record1, data_type1)

                if errors.empty?
                  handle_valid_record(record1, data_type1)
                else
                  handle_invalid_record(record1, data_type1, errors)
                end
              end
            end
          else
            handle_invalid_record(record, data_type, errors)
          end
        end

        if @interrupted
          handle_interrupted_run
        else
          handle_successful_run
        end
      rescue ScriptError => e
        handle_failed_run
      end
    end

    def interrupt
      @interrupted = true
    end

    private
    def transformers
      @config['transformers'] || []
    end

    def validate(record, data_type)
      schema = get_schema(data_type)
      errors = JSON::Validator.fully_validate(schema, record, :errors_as_objects => true)
      errors.map do |error|
        case error[:message]
        when /The property '#\/' did not contain a required property of '(\w+)'/
          "Missing required attribute: #{Regexp.last_match(1)}"
        else
          error[:message]
        end
      end
    end

    def get_schema(data_type)
      if !@schemas.has_key?(data_type)
        hyphenated_name = data_type.to_s.gsub("_", "-").gsub(" ", "-")
        @schemas[data_type] = File.expand_path("../../schema/schemas/#{hyphenated_name}-schema.json", __FILE__)
      end

      @schemas[data_type]
    end

    def handle_valid_record(record, data_type)
      raise NotImplementedError
    end

    def handle_invalid_record(record, data_type, errors)
      raise NotImplementedError
    end

    def handle_successful_run
    end

    def handle_interrupted_run
    end

    def handle_failed_run
      raise NotImplementedError
    end

    def run_script_each_line(command, options={})
      # TODO: handle timeouts, errors
      Open3::popen2(command) do |stdin, stdout, wait_thread|
        if options[:input]
          stdin.puts(options[:input])
          stdin.close
        end

        timeout = options[:timeout] || 3600

        while !@interrupted do
          begin
            result = stdout.readline.strip
            yield result unless result.empty?
          rescue EOFError
            break
          end
        end

        if !wait_thread.value.success?
          raise ScriptError
        end
      end
    end

    def scraper_file
      candidates = Dir.glob(File.join(@bot_directory, 'scraper.{rb,py}'))
      case candidates.size
      when 0
        raise 'Could not find scraper to run'
      when 1
        candidates.first
      else
        raise "Found multiple scrapers: #{candidates.join(', ')}"
      end
    end

    def interpreter_for(file)
      case file
      when /\.rb$/
        'ruby'
      when /\.py$/
        'python'
      else
        raise "Could not run #{file}"
      end
    end
  end
end

class Runner < TurbotRunner::BaseRunner
  def handle_valid_record(record, data_type)
    record[:data_type] = data_type
    STDOUT.puts(record.to_json)
  end

  def handle_invalid_record(record, data_type, errors)
    STDERR.puts
    STDERR.puts "The following record is invalid:"
    STDERR.puts record.to_json
    STDERR.errors.each {|error| puts " * #{error}"}
    STDERR.puts
  end

  def handle_failed_run
    STDERR.puts('Bot did not run to completion')
  end
end

runner = Runner.new('/repo')
