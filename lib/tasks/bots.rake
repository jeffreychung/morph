namespace :bots do
  desc "Run scrapers that need to run once per day (this task should be called from a cron job)"
  task :reindex_run_output => :environment do
    bot_id = ENV['BOT_ID']
    run_uid = ENV['RUN_UID']
    raise "Must specify BOT_ID and RUN_UID" unless bot_id && run_uid
    runner = TurbotDockerRunner.new(bot_id, "draft", run_uid, nil)
    runner.connect_to_rabbitmq
    runner.process_output
  end
end
