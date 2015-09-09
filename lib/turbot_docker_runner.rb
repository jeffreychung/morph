require 'json'
require 'zip'

class TurbotDockerRunner
  @queue = :turbot_docker_runs

  def self.perform(params)
    runner = TurbotDockerRunner.new(params)
    runner.run
  end

  def initialize(params)
    params = params.with_indifferent_access

    @params = params  # Keep hold of this for error reporting

    @bot_name = params[:bot_name]

    if params[:run_id] == 'draft'
      @run_id = 'draft'
    else
      @run_id = params[:run_id].to_i
    end

    @run_uid = params[:run_uid]
    @run_type = params[:run_type]
    @user_api_key = params[:user_api_key]
    @user_roles = params[:user_roles] || []
    @run_ended = false
  end

  def run
    set_up
    if @run_type == 'prescrape'
      status_code = 0
    else
      status_code = run_in_container
    end

    # TODO remove this restriction once SEC data is migrated.
    process_output unless @bot_name == 'sec_subsidiaries'

    zip_and_symlink_output

    metrics = read_metrics

    if !config['incremental'] && !config['manually_end_run'] # the former is legacy
      @run_ended = true
      send_run_ended_to_angler
    end

    report_run_ended(status_code, metrics)
  rescue Exception => e
    log_exception_and_notify_airbrake(e)

    report_run_ended(-1, {:class => e.class, :message => e.message, :backtrace => e.backtrace})
  ensure
    clean_up
  end

  def set_up
    set_up_directory(output_path)

    # We open these files as soon as possible so that we can log to them if
    # there's any error.
    @stdout_file = File.open(stdout_path, 'wb')
    @stdout_file.sync = true
    @stderr_file = File.open(stderr_path, 'wb')
    @stderr_file.sync = true

    connect_to_rabbitmq
    set_up_directory(tmp_path)
    set_up_directory(data_path)
    set_up_directory(downloads_path)
    synchronise_repo
  end

  def clean_up
    @stdout_file.close if (@stdout_file && !@stdout_file.closed?)
    @stderr_file.close if (@stderr_file && !@stderr_file.closed?)
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
    tries = 3

    if Dir.exists?(repo_path)
      begin
        Rails.logger.info("Pulling into #{repo_path}")
        Git.open(repo_path).pull
      rescue Git::GitExecuteError
        Rails.logger.info('Hit GitExecuteError')
        retry unless (tries -= 1).zero?
        raise
      end
    else
      begin
        Rails.logger.info("Cloning #{git_url} into #{repo_path}")
        Git.clone(git_url, repo_path)
      rescue Git::GitExecuteError
        Rails.logger.info('Hit GitExecuteError')
        retry unless (tries -= 1).zero?
        raise
      end

      # Bots using OpencBot's incrementors expect to be able to write to /repo/db.
      # This could be removed if OpencBot is made smarter.
      File.symlink(data_path, File.join(repo_path, 'db'))
    end
  end

  def run_in_container
    begin
      binds = [
        "#{repo_path}:/repo:ro",
        "#{tmp_path}:/tmp",
        "#{data_path}:/data",
        "#{local_root_path}/utils:/utils:ro",
        "#{output_path}:/output"
      ]
      if @user_roles.include?("admin")
        binds << "#{sources_path}:/sources"
        set_up_directory(sources_path)
      end

      container = create_container
      status_code = nil
      Rails.logger.info("Starting container with bindings: #{binds}")
      container.start('Binds' => binds)

      container.attach do |stream, chunk|
        case stream
        when :stdout
          @stdout_file.write(chunk)
        when :stderr
          @stderr_file.write(chunk)
        end
      end

    rescue Exception => e
      begin
        container.kill
      rescue Excon::Errors::SocketError => e
        Rails.logger.info("Could not kill container")
      end
      raise
    ensure
      Rails.logger.info('Waiting for container to finish')
      response = container.wait
      status_code = response['StatusCode'] if status_code.nil?
      Rails.logger.info('Deleting container')
      container.delete
    end

    Rails.logger.info("Returning with status_code #{status_code}")
    status_code
  end

  def create_container
    Rails.logger.info('Creating container')
    conn = Docker::Connection.new(docker_url, read_timeout: 3.months)
    container_params = {
      'name' => "#{@bot_name}_#{@run_uid}",
      'Cmd' => ['/bin/bash', '-l', '-c', command],
      'User' => 'scraper',
      'Image' => image,
      # We have 8GB to divide between 10 processes, but there's scope for
      # swapping and most processes won't need that much memory.
      'Memory' => 1.gigabyte,
      # MORPH_URL is used by Turbotlib to determine whether a scraper is
      # running in production.
      'Env' => ["RUN_TYPE=#{@run_type}", "MORPH_URL=#{ENV['MORPH_URL']}", "USER_ROLES=#{@user_roles.join(',')}"],
    }
    Rails.logger.info("Creating container with params #{container_params}")
    Docker::Container.create(container_params, conn)
  end

  def process_output
    Rails.logger.info('Processing output')
    handler = Handler.new(@bot_name, config, @run_id)
    runner = TurbotRunner::Runner.new(
      repo_path,
      :record_handler => handler,
      :output_directory => output_path,
      :timeout => 24 * 60 * 6
    )
    runner.process_output
    @run_ended = handler.ended
  end

  def zip_and_symlink_output
    zipfile_name = "#{@bot_name}-#{@run_uid}.zip"
    zipfile_path = File.join(output_path, zipfile_name)
    Zip::File.open(zipfile_path, Zip::File::CREATE) do |zipfile|
      script_output_filenames.each do |filename|
        begin
          zipfile.add(filename, File.join(output_path, filename))
        rescue Errno::ENOENT
          # An output file might not have been created (particularly in the
          # case of an incremental bot).
        end
      end
    end
    FileUtils.chmod(0755, zipfile_path)
    File.symlink(
      zipfile_path,
      File.join(downloads_path, zipfile_name)
    )
  end

  def docker_url
    ENV["DOCKER_URL"] || Docker.default_socket_url
  end

  def local_root_path
    ENV['DOCKER_URL'] ? "/vagrant" : Rails.root
  end

  def command
    '/usr/bin/time -v -o /output/time.out ruby /utils/wrapper.rb'
  end

  def image
    "opencorporates/morph-#{language}"
  end

  def language
    if File.exist?(File.join(repo_path, 'scraper.rb'))
      'ruby'
    elsif File.exist?(File.join(repo_path, 'scraper.py'))
      'python'
    else
      raise "Could not find scraper at #{repo_path}"
    end
  end

  def script_output_filenames
    filenames = ["scraper.out"]
    (config['transformers'] || []).each do |transformer_config|
      transformer_file = transformer_config['file']
      basename = File.basename(transformer_file, script_extension)
      filenames << "#{basename}.out"
    end
    filenames
  end

  def script_extension
    {
      'ruby' => '.rb',
      'python' => '.py',
    }[language]
  end

  def send_run_ended_to_angler
    message = {
      :type => 'run.ended',
      :bot_name => @bot_name,
      :snapshot_id => @run_id
    }
    Hutch.publish('bot.record', message)
  end

  def read_metrics
    metrics = {}

    begin
      File.readlines(File.join(output_path, 'time.out')).each do |line|
        field, value = parse_metric_line(line)
        metrics[field] = value if value
      end
    rescue Errno::ENOENT
      # sometimes time.out doesn't get produced
    end

    # There's a bug in GNU time 1.7 which wrongly reports the maximum resident
    # set size on the version of Ubuntu that we're using.
    # See https://groups.google.com/forum/#!topic/gnu.utils.help/u1MOsHL4bhg
    unless metrics.empty?
      raise "Page size not known" unless metrics[:page_size]
      metrics[:maxrss] = metrics[:maxrss] * 1024 / metrics[:page_size]
    end

    num_records = 0

    begin
      File.readlines(File.join(output_path, 'scraper.out')).each {|line| num_records += 1}
    rescue Errno::ENOENT
    end

    metrics[:num_records] = num_records

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

  def report_run_ended(status_code, metrics)
    # TODO find the right place to put this
    host = ENV['TURBOT_HOST'] || 'http://turbot'
    url = "#{host}/api/runs/#{@run_uid}"

    params = {
      :api_key => ENV['TURBOT_API_KEY'],
      :status_code => status_code,
      :metrics => metrics,
      :run_ended => @run_ended
    }

    Rails.logger.info("Reporting run ended to #{url}")
    RestClient.put(url, params.to_json, :content_type => 'application/json')
  end

  def config
    @config ||= JSON.parse(File.read(File.join(repo_path, 'manifest.json')))
  end

  def repo_path
    File.join(
      base_path,
      'repo',
      @bot_name[0],
      @bot_name
    )
  end

  def tmp_path
    File.join(
      base_path,
      'tmp',
      @bot_name[0],
      @bot_name,
      @run_uid.to_s
    )
  end

  def data_path
    File.join(
      base_path,
      'data',
      @bot_name[0],
      @bot_name
    )
  end

  def output_path
    File.join(
      base_path,
      'output',
      @run_id == 'draft' ? 'draft' : 'non-draft',
      @bot_name[0],
      @bot_name,
      @run_uid.to_s
    )
  end

  def sources_path
    if Rails.env.production?
      base = '/oc/openc/sources/bots'
    else
      base = 'sources'
    end
    File.join(
      base,
      @bot_name
    )
  end

  def downloads_path
    File.join(
      base_path,
      'downloads',
      @bot_name[0],
      @bot_name,
      @run_uid.to_s,
      @user_api_key
    )
  end

  def stdout_path
    File.join(output_path, 'stdout')
  end

  def stderr_path
    File.join(output_path, 'stderr')
  end

  def git_url
    "git@#{GITLAB_DOMAIN}:#{GITLAB_GROUP}/#{@bot_name}.git"
  end

  def base_path
    if Rails.env.production?
      '/oc/openc/scrapers'
    else
      'db/scrapers'
    end
  end

  def log_exception_and_notify_airbrake(e)
    Rails.logger.error("Hit error when running container: #{e}")
    unless @stderr_file.nil?
      @stderr_file.puts("Hit error when running container: #{e}")
      e.backtrace.each do |line|
        Rails.logger.error(line)
        @stderr_file.puts(line)
      end
    end
    Airbrake.notify(e, :parameters => @params)
  end
end
