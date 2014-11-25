class RunsController < ApplicationController
  skip_before_filter :verify_authenticity_token

  def run
    Resque.enqueue(TurbotDockerRunner, params)
    head :ok
  end
end
