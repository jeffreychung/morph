class AddRunParamsToRuns < ActiveRecord::Migration
  def change
    add_column :runs, :run_params, :text
  end
end
