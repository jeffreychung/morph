class DelayedRunWorker
  include Sidekiq::Worker
  sidekiq_options queue: :low

  def perform(run_id)
    Rails.logger.info("DelayedRunWorker performing with run #{run_id}")
    run = Run.find(run_id)
    scraper = run.scraper

    if scraper.runnable?
      Rails.logger.info("DelayedRunWorker running scraper #{scraper.name}")
      run.synch_and_go!
    else
      Rails.logger.info("Scraper #{scraper.name} not runnable")
    end
  end
end

