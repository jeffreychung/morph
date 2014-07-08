require 'turbot_api'

class Run < ActiveRecord::Base
  include Sync::Actions
  belongs_to :owner
  belongs_to :scraper, inverse_of: :runs, touch: true
  has_many :log_lines
  has_one :metric
  has_many :connection_logs

  delegate :git_url, :full_name, to: :scraper
  delegate :current_revision_from_repo, to: :scraper, allow_nil: true
  delegate :utime, :stime, to: :metric, allow_nil: true

  def database
    Morph::Database.new(data_path)
  end

  def cpu_time
    begin
      utime + stime
    rescue NoMethodError
      0
    end
  end

  def language
    Morph::Language.language(repo_path)
  end

  def finished_at=(time)
    write_attribute(:finished_at, time)
    update_wall_time
  end

  def update_wall_time
    if started_at && finished_at
      write_attribute(:wall_time, finished_at - started_at)
    end
  end

  def wall_time=(t)
    raise "Can't set wall_time directly"
  end

  def name
    if scraper
      scraper.name
    else
      # This run is using uploaded code and so is not associated with a scraper
      "run"
    end
  end

  def data_path
    "#{owner.data_root}/#{name}"
  end

  def repo_path
    "#{owner.repo_root}/#{name}"
  end

  def queued?
    queued_at && started_at.nil?
  end

  def running?
    started_at && finished_at.nil?
  end

  def finished?
    !!finished_at
  end

  def finished_with_errors?
    finished? && !finished_successfully?
  end

  def error_text
    log_lines.where(stream: "stderr").order(:number).map{|l| l.text}.join
  end

  def finished_successfully?
    finished? && status_code == 0
  end

  def self.time_output_filename
    "time.output"
  end

  def time_output_path
    File.join(data_path, Run.time_output_filename)
  end

  def docker_container_name
    "#{owner.to_param}_#{name}_#{id}"
  end

  def docker_image
    if language == "ruby"
      "opencorporates/morph-#{language}"
    else
      "opencorporates/morph-#{language}"
    end
  end

  def git_revision_github_url
    "https://github.com/#{full_name}/commit/#{git_revision}"
  end

  def go_with_logging
    puts "Starting...\n"
    database.backup
    update_attributes(started_at: Time.now, git_revision: current_revision_from_repo)
    sync_update scraper if scraper
    FileUtils.mkdir_p data_path
    FileUtils.chmod 0777, data_path

    unless Morph::Language.language_supported?(language)
      supported_scraper_files = Morph::Language.languages_supported.map do |l|
        Morph::Language.language_to_scraper_filename(l)
      end.to_sentence(last_word_connector: ", or ")
      yield "stderr", "Can't find scraper code. Expected to find a file called " +
         supported_scraper_files + " in the root directory"
      update_attributes(status_code: 999, finished_at: Time.now)
      return
    end

    if run_params.present?
      run_id = "update"
    else
      # Notify turbot that run is starting, and get run_id
      #run_id = turbot_api.start_run(name).data[:run_id]
      run_id = 123
    end

    config = {
      :name => name,
      :run_id => run_id,
      :run_params => run_params,
    }

    File.open(File.join(repo_path, 'runtime.json'), 'w') do |f|
      f.write(config.to_json)
    end

    command = [
      Morph::Language.binary_name(:ruby),
      '/utils/angler-wrapper.rb',
      Morph::Language.scraper_command(language),
    ]

    command = Metric.command(command.join(' '), Run.time_output_filename)
    status_code = Morph::DockerRunner.run(
      command: command,
      image_name: docker_image,
      container_name: docker_container_name,
      repo_path: repo_path,
      data_path: data_path
    ) do |on|
        on.log { |s,c| yield s, c}
        on.ip_address do |ip|
          # Store the ip address of the container for this run
          update_attributes(ip_address: ip)
        end
    end

    # Now collect and save the metrics
    begin
      metric = Metric.read_from_file(time_output_path)
      metric.update_attributes(run_id: self.id)
    rescue Errno::ENOENT
      # No metrics got generated; let the run complete anyway
    end

    update_attributes(status_code: status_code, finished_at: Time.now)
    # Update information about what changed in the database
    diffstat = Morph::Database.diffstat(database.sqlite_db_backup_path, database.sqlite_db_path)
    tables = diffstat[:tables][:counts]
    records = diffstat[:records][:counts]
    update_attributes(
      tables_added: tables[:added],
      tables_removed: tables[:removed],
      tables_changed: tables[:changed],
      tables_unchanged: tables[:unchanged],
      records_added: records[:added],
      records_removed: records[:removed],
      records_changed: records[:changed],
      records_unchanged: records[:unchanged]
    )
    Morph::Database.tidy_data_path(data_path)
    if scraper
      scraper.update_sqlite_db_size
      scraper.reload
      sync_update scraper
    end

    # Notify turbot that run has finished
    #turbot_api.stop_run(name) unless run_params.present?
  end

  def log(stream, text)
    puts "#{stream}: #{text}"
    number = log_lines.maximum(:number) || 0
    line = log_lines.create(stream: stream.to_s, text: text, number: (number + 1))
    sync_new line, scope: self
  end

  def go!
    go_with_logging do |s,c|
      log(s, c)
    end
  end

  # The main section of the scraper running that is run in the background
  def synch_and_go!
    # If this run belongs to a scraper that has just been deleted then don't do anything
    if scraper
      Morph::Github.synchronise_repo(repo_path, git_url)
      go!
    end
  end

  private
  def turbot_api
    @turbot_api ||= Turbot::API.new(
      :host => ENV['TURBOT_HOST'] || 'http://turbot',
      :api_key => ENV['TURBOT_API_KEY'],
    )
  end
end
