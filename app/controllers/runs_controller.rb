class RunsController < ApplicationController
  skip_before_filter :verify_authenticity_token

  def run
    runner = Runner.new(params[:bot_name], params[:run_id], params[:run_uid])
    runner.run
  end
end
