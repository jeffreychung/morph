class RunsController < ApplicationController
  skip_before_filter :verify_authenticity_token

  def run
    Resque.enqueue(Runner, params[:bot_name], params[:run_id], params[:run_uid], :bot_type => params[:bot_type])
    head :ok
  end
end
