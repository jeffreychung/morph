class DelayedRunWorker
  include Sidekiq::Worker
  sidekiq_options queue: :low

  def perform(run_id)
    Rails.logger.info("DelayedRunWorker performing with run #{run_id}")
    run = Run.find(run_id)
    scraper = run.scraper
    Rails.logger.info("DelayedRunWorker performing with scraper #{scraper.name}")
    run.synch_and_go!
  end
end

