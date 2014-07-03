class Runner
  @queue = :runs

  def self.perform(bot_name, run_id, run_uid)
    runner = Runner.new(bot_name, run_id, run_uid)
    runner.run
  end

  def initialize(bot_name, run_id, run_uid, run_params={})
    @bot_name = bot_name
    @run_id = run_id
    @run_uid = run_uid
    @run_params = run_params
  end

  def run
    set_up

    status_code = run_in_container do |stream, chunk|
      case stream
      when :stdout
        handle_stdout(chunk)
      when :stderr
        handle_stderr(chunk)
      end
    end

    metrics = read_metrics(File.join(data_path, 'time.out'))
    output = File.read(stderr_out_path)
    
    report_run_ended(status_code, metrics, output)
  ensure
    clean_up
  end

  def set_up
    connect_to_rabbitmq
    set_up_directory(data_path)
    set_up_directory(metadata_path)
    synchronise_repo
    write_runtime_config

    @num_records = 0
    @stdout_buffer = ''
    @stderr_file = File.open(stderr_out_path, 'w')
  end

  def clean_up
    @stderr_file.close unless @stderr_file && @stderr_file.closed?
  end

  def connect_to_rabbitmq
    return if Hutch.connected?
    Rails.logger.info('Connecting to RabbitMQ')
    Hutch.connect({}, HutchConfig)
  end

  def set_up_directory(path)
    Rails.logger.info("Setting up #{path}")
    FileUtils.mkdir_p(path)
    FileUtils.chmod(0777, path)
  end

  def synchronise_repo
    if Dir.exists?(repo_path)
      Rails.logger.info("Pulling into #{repo_path}")
      Git.open(repo_path).pull
    else
      Rails.logger.info("Cloning #{git_url} into #{repo_path}")
      Git.clone(git_url, repo_path)
    end
  end

  def write_runtime_config
    runtime_config = {
      :name => @bot_name,
      :run_params => @run_params,
    }

    File.open(File.join(repo_path, 'runtime.json'), 'w') do |f|
      f.write(runtime_config.to_json)
    end
  end

  def run_in_container
    container = create_container

    begin
      binds = [
        "#{local_root_path}/#{repo_path}:/repo:ro",
        "#{local_root_path}/#{data_path}:/data",
        "#{local_root_path}/utils:/utils:ro"
      ]
      Rails.logger.info("Starting container with bindings: #{binds}")
      container.start('Binds' => binds)

      container.attach(:logs => true) do |stream, chunk|
        yield stream, chunk
      end

      status_code = container.json['State']['ExitCode']

    rescue Exception => e
      # TODO handle error here
      Rails.logger.info("Hit error when running container: #{e}")
      container.kill
    ensure
      Rails.logger.info('Waiting for container to finish')
      container.wait
      Rails.logger.info('Deleting container')
      container.delete
    end

    Rails.logger.info("Returning with status_code #{status_code}")
    status_code
  end

  def create_container
    conn = Docker::Connection.new(docker_url, chunk_size: 1, read_timeout: 4.hours)
    begin  
      container_params = {
        'name' => "#{@bot_name}_#{@run_uid}",
        'Cmd' => ['/bin/bash', '-l', '-c', command],
        'User' => 'scraper',
        # TODO handle non-ruby scrapers
        'Image' => 'opencorporates/morph-ruby',
        # See explanation in https://github.com/openaustralia/morph/issues/242
        'CpuShares' => 307,
        # On a 1G machine we're allowing a max of 10 containers to run at a time. So, 100M
        # TODO check this is right for openc use case
        'Memory' => 100.megabytes,
      }
      Rails.logger.info("Creating container with params #{container_params}")
      Docker::Container.create(container_params, conn)
    rescue Excon::Errors::SocketError => e
      Rails.logger.info("Hit connection error: #{e}")
      # TODO handle error here
      raise
    end
  end

  def docker_url
    ENV["DOCKER_URL"] || Docker.default_socket_url
  end

  def local_root_path
    ENV['DOCKER_URL'] ? "/vagrant" : Rails.root
  end

  def command
    "/usr/bin/time -v -o time.out ruby /utils/runner.rb #{@bot_name}"
  end

  def handle_stdout(chunk)
    *lines, @stdout_buffer = (@stdout_buffer + chunk).lines

    lines.each do |line|
      handle_stdout_line(line)
    end
  end

  def handle_stdout_line(line)
    case line.strip
    when 'NOT FOUND'
      # TODO
    when 'RUN ENDED'
      # TODO
    else
      data = JSON.parse(chunk)
      data_type = data.delete('data_type')
      record = {
        type: 'bot.record',
        bot_name: @bot_name,
        run_id: @run_id,
        data: data,
        export_date: Time.now.iso8601,
        data_type: data_type,
        identifying_fields: identifying_fields_for(data_type),
      }
      send_to_angler(record)
    end
  end

  def send_to_angler(record)
    @num_records += 1
    Hutch.publish('bot.record', record)
  end

  def handle_stderr(chunk)
    @stderr_file.write(chunk)
  end

  def read_metrics(path)
    metrics = {}

    File.readlines(path).each do |line|
      field, value = parse_metric_line(line)
      metrics[field] = value if value
    end

    # There's a bug in GNU time 1.7 which wrongly reports the maximum resident
    # set size on the version of Ubuntu that we're using.
    # See https://groups.google.com/forum/#!topic/gnu.utils.help/u1MOsHL4bhg
    unless metrics.empty?
      raise "Page size not known" unless metrics[:page_size]
      metrics[:maxrss] = metrics[:maxrss] * 1024 / metrics[:page_size]
    end

    metrics
  end

  def parse_metric_line(line)
    field, value = line.split(": ")

    case field
    when /Maximum resident set size \(kbytes\)/
      [:maxrss, value.to_i]
    when /Minor \(reclaiming a frame\) page faults/
      [:minflt, value.to_i]
    when /Major \(requiring I\/O\) page faults/
      [:majflt, value.to_i]
    when /User time \(seconds\)/
      [:utime, value.to_f]
    when /System time \(seconds\)/
      [:stime, value.to_f]
    when /Elapsed \(wall clock\) time \(h:mm:ss or m:ss\)/
      n = value.split(":").map{|v| v.to_f}
      if n.count == 2
        m, s = n
        h = 0
      elsif n.count == 3
        h, m, s = n
      end
      [:wall_time, (h * 60 + m) * 60 + s ]
    when /File system inputs/
      [:inblock, value.to_i]
    when /File system outputs/
      [:oublock, value.to_i]
    when /Voluntary context switches/
      [:nvcsw, value.to_i]
    when /Involuntary context switches/
      [:nivcsw, value.to_i]
    when /Page size \(bytes\)/
      [:page_size, value.to_i]
    end
  end

  def report_run_ended(status_code, metrics, output)
    # TODO find the right place to put this
    host = ENV['TURBOT_HOST'] || 'http://turbot'
    url = "#{host}/api/runs/#{@run_uid}"

    params = {
      :api_key => ENV['TURBOT_API_KEY'],
      :status_code => status_code,
      :metrics => metrics,
      :output => output
    }

    Rails.logger.info("Reporting run ended to #{url}")
    RestClient.put(url, params.to_json, :content_type => 'application/json')
  end

  def repo_path
    File.join(BASE_PATH, 'repo', @bot_name)
  end
  
  def data_path
    File.join(BASE_PATH, 'data', @bot_name)
  end
  
  def metadata_path
    File.join(BASE_PATH, 'metadata', @bot_name)
  end

  def git_url
    "git@#{GITLAB_DOMAIN}:#{GITLAB_GROUP}/#{@bot_name}.git"
  end

  def stderr_out_path
    File.join(metadata_path, 'stderr.out')
  end
end
