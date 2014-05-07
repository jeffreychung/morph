class ApiController < ApplicationController
  include ActionController::Live

  # The run_remote method will be secured with a key so shouldn't need csrf token authentication
  skip_before_filter :verify_authenticity_token, :only => [:run_remote, :create_from_git]

  def test
    count = 0
    response.headers['Content-Type'] = 'text/event-stream'
    3.times do
      data = "Hello! (#{count})"
      response.stream.write(data + "\n")
      puts "Sending: #{data}"
      count += 1
      sleep 1
    end
    response.stream.close
  end

  # Receive code from a remote client, run it and return the result.
  # This will be a long running request
  def run_remote
    puts "**** IN RUN_REMOTE ****"
    # TODO: Get the id of the person making the request and set current_user.
    user = User.find_by_api_key(params[:api_key])
    if user.nil?
      render :text => "API key is not valid", status: 401
    else
      run = Run.create(queued_at: Time.now, auto: false, owner_id: user.id)

      Archive::Tar::Minitar.unpack(params[:code].tempfile, run.repo_path)
      #Archive::Tar::Minitar.unpack(params[:code].tempfile, "uploaded_files")

      result = []
      response.headers['Content-Type'] = 'text/event-stream'
      run.go_with_logging do |s,text|
        response.stream.write({stream: s, text: text}.to_json + "\n")
      end
      response.stream.close

      # Cleanup run
      FileUtils.rm_rf(run.data_path)
      FileUtils.rm_rf(run.repo_path)
    end
  end

  def create_from_git
    git_url = params[:git_url]
    match = git_url.match(/.*\/(.*?)(\.git)?$/)
    name = match && match[1] || ""
    owner = User.find_or_create_by(name: "OpenCorporates", nickname: "openc")
    owner.save!
    @scraper = Scraper.find_or_create_by(name: name, full_name: "openc/#{name}",
      description: "", github_id: "", owner: owner,
      github_url: "", git_url: git_url)
    if !match
      @scraper.errors.add(:git_url, "is not parseable")
      render json: @scraper.errors.to_json
    elsif @scraper.save
      @scraper.synchronise_repo
    end
    render json: @scraper.to_json
  end
end
