namespace :reprocess do
  desc "Reprocess runs"
  task :runs => :environment do
    bot_id = ENV.fetch("bot_id")
    snapshot_id = ENV.fetch("snapshot_id")
    run_uids = ENV.fetch("run_uids").split(",").map(&:to_i)

    run_ids.each do |run_uid|
      runner = TurbotDockerRunner.new(
        :bot_name => bot_id,
        :run_id => snapshot_id,
        :run_uid => run_uid,
      )

      runner.process_output
    end
  end
end
