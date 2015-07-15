# Much of this was taken from http://www.slideshare.net/keenanbrock/resque-5509733
require "resque/tasks"
require 'resque/scheduler/tasks'

def log(msg)
  puts "#{Process.pid} :: #{Time.now} :: #{msg}"
end

task "resque:setup" => :environment do
  # generic worker setup, e.g. Hoptoad for failed jobs
end

namespace :resque do

  desc "Start a Resque worker without forking"
  task :work_dont_fork => [ :preload, :setup ] do
    log("*" * 80)
    log("Running rake task resque:work_dont_fork")
    require 'resque'

    queues = (ENV['QUEUES'] || ENV['QUEUE']).to_s.split(',')
    log("queues: #{queues}")

    begin
      worker = Resque::Worker.new(*queues)
      worker.cant_fork = true
      if ENV['LOGGING'] || ENV['VERBOSE']
        worker.verbose = ENV['LOGGING'] || ENV['VERBOSE']
      end
      if ENV['VVERBOSE']
        worker.very_verbose = ENV['VVERBOSE']
      end
      worker.term_timeout = ENV['RESQUE_TERM_TIMEOUT'] || 4.0
      worker.term_child = ENV['TERM_CHILD']
      worker.run_at_exit_hooks = ENV['RUN_AT_EXIT_HOOKS']
    rescue Resque::NoQueueError
      abort "set QUEUE env var, e.g. $ QUEUE=critical,high rake resque:work"
    end

    if ENV['BACKGROUND']
      unless Process.respond_to?('daemon')
          abort "env var BACKGROUND is set, which requires ruby >= 1.9"
      end
      Process.daemon(true)
    end

    if ENV['PIDFILE']
      File.open(ENV['PIDFILE'], 'w') { |f| f << worker.pid }
    end

    worker.log "Starting worker #{worker}"

    log("Starting worker")
    rc = worker.work(ENV['INTERVAL'] || 5) # interval, will block
    log("Worker has completed, returning: #{rc}")
    rc
  end


  desc 'start all background resque daemons'
  task :start_daemons do
    puts workers_config
    workers_config().each do |worker, config|
      task_details = "resque_#{worker} resque:work_dont_fork QUEUE=#{config['queues']} #{config['cl_params']}"
      mrake_start task_details
    end
  end

  desc 'stop all background resque daemons'
  task :stop_daemons do
    sh "./script/monit_rake stop resque_scheduler"
    workers_config.each do |worker, config|
      sh "./script/monit_rake stop resque_#{worker} -s QUIT"
    end
    workers_config('restricted').each do |worker, config|
      sh "./script/monit_rake stop resque_#{worker} -s QUIT"
    end
    puts "Stopped all background resque daemons. Now clearing all restricted_performer locks..."
    Rake::Task["resque:clear_performer_locks"].invoke
    puts "Done."
  end

  desc 'start restricted resque daemons'
  task :start_restricted_resque_daemons do
    workers_config('restricted').each do |worker, config|
      start_hour,stop_hour = config['permitted_hours'].split('..').collect(&:to_i)
      current_hour = Time.now.hour
      time_boundary = Range.new(start_hour,stop_hour)
      # only want to do reverse boundary if it crosses over midnight
      reverse_time_boundary = Range.new(stop_hour,start_hour) if stop_hour < start_hour
      if time_boundary.include?(current_hour) or (reverse_time_boundary and not reverse_time_boundary.include?(current_hour))
        puts "About to restart resque worker: #{worker}"
        # stop..if it's running
        sh "./script/monit_rake stop resque_#{worker} -s QUIT"
        task_details = "resque_#{worker} resque:work_dont_fork QUEUE=#{config['queues']}"
        # ..and start again
        mrake_start task_details
      else
        # stop
        puts "Stopping resque worker if running: #{worker}"
        sh "./script/monit_rake stop resque_#{worker} -s QUIT"
      end
    end
  end

  desc 'stop and then restart all background resque daemons'
  task :restart_daemons do
    Rake::Task["resque:stop_daemons"].invoke
    Rake::Task["resque:start_daemons"].invoke
  end

  desc 'clear all restricted_performer locks'
  task :clear_performer_locks => :environment do
    Resque.redis.keys.select{ |k| k.match /performer_lock/ }.each{ |k| Resque.redis.del(k) }
  end

  desc 'clear specific restricted_performer lock'
  task :clear_performer_lock => :environment do
    locks = Resque.redis.keys.select{ |k| k.match /performer_lock/ }
    puts "Which lock do you want to clear:"
    locks.each_with_index do |lock, i|
      puts "#{i}. #{lock}"
    end
    lock_to_clear = $stdin.gets.chomp
    Resque.redis.del(locks[lock_to_clear.to_i])
    puts "Cleared lock: #{locks[lock_to_clear.to_i]}"
  end

  desc 'move queued items to new queue'
  task :move_queued_items => :environment do
    i = 0
    unless source_queue = ENV['QUEUE_NAME']
      puts "FROM which queue do you want to move items [after_create]"
      response = $stdin.gets.chomp
      source_queue = response.blank? ? :after_create : response.to_sym
    end
    unless dest_queue = ENV['DEST_QUEUE']
      puts "TO which queue do you want to move items [low]"
      response = $stdin.gets.chomp
      dest_queue = response.blank? ? :low : response.to_sym
    end
    unless quantity = ENV['QUANTITY']
      puts "How many items do you want to move [all]"
      response = $stdin.gets.chomp
      quantity = response.blank? ? :all : response.to_i
    end
    puts "About to move #{quantity} items from #{source_queue} queue to #{dest_queue} queue"
    while obj = Resque.pop(source_queue)
      Resque.push(dest_queue, obj)
      i+=1
      break if quantity.is_a?(Fixnum) and i >= quantity
      print '.'
    end
    puts "Successfully moved #{i} items from #{source_queue} queue to #{dest_queue} queue"
  end

  desc 'move items to back of queue'
  task :move_to_back_of_queue => :environment do
    unless source_queue = ENV['QUEUE_NAME']
      puts "From which queue do you want to move items to back [low]"
      response = $stdin.gets.chomp
      source_queue = response.blank? ? :low : response.to_sym
    end
    unless quantity = ENV['QUANTITY']
      puts "How many items do you want to move to back of queue [5]"
      response = $stdin.gets.chomp
      quantity = response.blank? ? 5 : response.to_i
    end
    quantity.times do
      obj = Resque.pop(source_queue)
      Resque.push(source_queue, obj)
    end
    puts "Successfully moved #{quantity} items from #{source_queue} queue to back"
  end

  desc 'move items to another queue based on the args (supply a regexp that the to_s version of the args can match)'
  task :move_queued_items_by_args => :environment do
    unless source_queue = ENV['QUEUE_NAME']
      puts "FROM which queue do you want to move items [after_create]"
      response = $stdin.gets.chomp
      source_queue = response.blank? ? :after_create : response.to_sym
    end
    unless dest_queue = ENV['DEST_QUEUE']
      puts "TO which queue do you want to move items [low]"
      response = $stdin.gets.chomp
      dest_queue = response.blank? ? :low : response.to_sym
    end
    unless matcher = ENV['MATCHER']
      puts "supply regexp to match to_s version of args to"
      matcher = $stdin.gets.chomp
    end
    matcher = Regexp.new(matcher)
    unless allowed_non_matches = ENV['ALLOWED_NON_MATCHES']
      puts "max number of non-matching items before halting [0]?"
      response = $stdin.gets.chomp
      allowed_non_matches = response.blank? ? 0 : response.to_i
    end
    failed_match = false
    items_moved = 0
    non_matches = 0
    while (non_matches < allowed_non_matches) or !failed_match do
      break unless obj = Resque.pop(source_queue)
      if obj["args"].to_s.match(matcher)
        Resque.push(dest_queue, obj)
        items_moved +=1
        non_matches = 0 # reset
        failed_match = false #reset this too
      else
        Resque.push(source_queue, obj)
        failed_match = true
        non_matches += 1
      end
    end
    puts "Successfully moved #{items_moved} items from #{source_queue} queue to #{dest_queue}"
  end

  desc 'truncate queue'
  task :truncate_queue => :environment do
    unless source_queue = ENV['QUEUE_NAME']
      puts "From which queue do you want to move items to back [low]"
      response = $stdin.gets.chomp
      source_queue = response.blank? ? :low : response.to_sym
    end
    unless quantity = ENV['SIZE']
      puts "How many items do you reduce queue to [100,000]"
      response = $stdin.gets.chomp
      new_size = response.blank? ? 100000 : response.to_i
    end
    Resque.redis.ltrim("queue:#{source_queue}", 0, new_size-1)
  end

  desc 'truncate gb_low queue'
  task :truncate_gb_low_queue => :environment do
    Resque.redis.ltrim("queue:gb_low", 0, 49999)
    Resque.redis.ltrim("queue:gb_medium", 0, 99999)
  end

  desc 'remove duplicates from queue'
  task :remove_duplicates_from_queue => :environment do
    unless source_queue = ENV['QUEUE_NAME']
      puts "Which queue do you want to dedupe"
      source_queue = $stdin.gets.chomp.to_sym
    end
    unless quantity = ENV['QUANTITY']
      puts "How many items do you want to dedupe from"
      response = $stdin.gets.chomp
      quantity = response.to_i
    end
    puts "About to dedupe from #{quantity} items on #{source_queue} queue"
    running_list = []
    dupes = 0
    while obj = Resque.pop(source_queue)
      if running_list.include?(obj)
        dupes += 1
      else
        running_list << obj
        Resque.push(source_queue,obj)
      end
      # else forget about it
      quantity -= 1
      break if quantity < 1
    end
    puts "Removed #{dupes} duplicates out of #{quantity} from #{source_queue} queue"
  end

  desc 'unregister all workers'
  task :unregister_workers => :environment do
    Resque.workers.each(&:unregister_worker)
  end

  desc 'kill remaining workers'
  task :kill_remaining_workers => :environment do
    command = "kill -9  `ps aux | grep [r]esque | grep -v grep | cut -c 10-16`"
    system command
  end

  desc 'move all failures to delayed_high queue for retrying'
  task :move_failures_to_delayed_high do
    (Resque::Failure.count-1).downto(0).each do |i|
      item = Resque::Failure.all(i)
      Resque::Job.create(:delayed_high, item['payload']['class'], *item['payload']['args'])
      Resque::Failure.remove(i)
    end
  end

  desc 'rename queue'
  task :move_all_in_queue do
    puts "Which queue do you want to move from?"
    source_queue = $stdin.gets.chomp
    puts "Which queue do you want to move to?"
    dest_queue = $stdin.gets.chomp
    Resque.redis.rename "queue:#{source_queue}", "queue:#{dest_queue}"
    puts "done"
  end

  def self.workers_config(queue_suffix=nil)
    YAML.load(open("config/resque_workers.yml").read)
  end

  def self.mrake_start(task_details)
    sh "nohup ./script/monit_rake start #{task_details} RAILS_ENV=#{ENV['RAILS_ENV']} >> log/daemons.log &"
  end
end
