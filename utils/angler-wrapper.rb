require 'json'
require 'base64'
require 'shellwords'
require 'hutch'
require 'open3'
require 'ostruct' # work around bug in hutch
require 'hutch/logging'
require 'time'
require 'turbot_api'

def connect_to_hutch
  config = Hutch::Config
  config.set(:mq_host, 'rabbit1.opencorporates.internal')
  config.set(:mq_api_host, 'rabbit1.opencorporates.internal')
  config.set(:mq_api_port, 55672)
  config.set(:mq_vhost, '/')
  config.set(:log_level, Logger::WARN)
  Hutch.connect({}, config)
end

def send
  connect_to_hutch

  manifest = parsed_config('manifest.json')
  config = parsed_config('runtime.json')

  puts "Started bot #{config['name']}, run #{config['run_id']}..."

  args = ARGV.clone

  args << config['name']

  if config['run_params']
    args << Shellwords.shellescape(config['run_params'])
  end

  count = 0
  command_output_each_line(args.join(" "), {}) do |line|
    if line.strip == 'NOT FOUND'
      line = {
        data: JSON.parse(run_params),
        end_date: Time.now.iso8601,
        end_date_type: 'before'
      }
    else
      line = {
        data: JSON.parse(line),
        export_date: Time.now.iso8601
      }
      line[:data_type] = manifest["data_type"]
      line[:identifying_fields] = manifest["identifying_fields"]
    end

    line[:bot_name] = manifest["bot_id"]
    line[:run_id] = config['run_id']
    line[:type] = 'bot.record'
    Hutch.publish('bot.record', line)
    count += 1
  end

  unless manifest['stateful']
    message = {
      :type => 'run.ended',
      :bot_name => manifest['bot_id'],
      :run_id => config['run_id'],
    }
    Hutch.publish('bot.record', message)
  end

  puts "Finished. Wrote #{count} records"
end

def command_output_each_line(command, options={})
  Open3::popen3(command, options) do |_, stdout, stderr, wait_thread|
    loop do
      check_output_with_timeout(stdout)

      begin
        result = stdout.readline.strip.force_encoding('utf-8')
        yield result unless result.empty?
        # add run id and bot name
      rescue EOFError
        break
      end
    end
    status = wait_thread.value.exitstatus
    if status > 0
      message = "Bot <#{command}> exited with status #{status}: #{stderr.read}"
      raise RuntimeError.new(message)
    end
  end
end

def check_output_with_timeout(stdout, initial_interval = 10, timeout = 21600)
  interval = initial_interval
  loop do
    reads, _, _ = IO.select([stdout], [], [], interval)
    break if !reads.nil?
    raise "Timeout! - could not read from external bot after #{timeout} seconds" if reads.nil? && interval > timeout
    interval *= 2
  end
end

def parsed_config(filename)
  begin
    path = "/repo/#{filename}"
    JSON.parse(open(path).read)
  rescue Errno::ENOENT
    raise "Missing `#{filename}`!"
  end
end

send()
