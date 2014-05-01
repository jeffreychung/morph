namespace :app do
  desc "Run scrapers that need to run once per day (this task should be called from a cron job)"
  task :auto_run_scrapers => :environment do
    # All the scrapers that need running in a random order
    scraper_ids = Scraper.where(auto_run: true).map{|s| s.id}.shuffle
    interval = 24.hours / scraper_ids.count
    time = 0
    scraper_ids.each do |scraper_id|
      ScraperAutoRunWorker.perform_in(time, scraper_id)
      time += interval
    end
    puts "Queued #{scraper_ids.count} scrapers to run over the next 24 hours"
  end

  desc "Send out alerts for all users (Run once per day with a cron job)"
  task :send_alerts => :environment do
    User.process_alerts
  end

  desc "Refresh info for all users from github"
  task :refresh_all_users => :environment do
    User.all.each {|user| user.refresh_info_from_github!}
  end

  desc "Build docker image (Needs to be done once before any scrapers are run)"
  task :update_docker_image => :environment do
    Scraper.update_docker_image!
  end

  desc "Synchronise all repositories"
  task :synchronise_repos => :environment do
    Scraper.all.each{|s| s.synchronise_repo}
  end

  desc "Add a scraper from a git location"
  task :add_scraper => :environment do
    puts "Which git URI do you want to clone?"
    puts "(e.g. file:///home/seb/Code/simple_bot_ng)"
    git_uri = $stdin.gets.chomp
    match = git_uri.match(/.*\/(.*?)(\.git)?$/)
    if match
      name = match[1]
      puts name
      # nickname is required as it's the friendlyid
      owner = User.new(name: "Seb", nickname: "seb")
      owner.save!
      scraper = Scraper.new(name: name, full_name: "seb/#{name}",
        description: "", github_id: "", owner: owner,
        github_url: "", git_url: git_uri)
      scraper.save!
      scraper.synchronise_repo
    else
      puts "Not a valid git URI"
    end
  end



end
