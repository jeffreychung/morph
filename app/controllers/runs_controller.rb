class RunsController < ApplicationController
  skip_before_filter :verify_authenticity_token

  def run
    Resque.enqueue(
      TurbotDockerRunner,
      params[:bot_name],
      params[:run_id],
      params[:run_uid],
      params[:run_type],
      params[:user_api_key]
    )
    head :ok
  end
end
