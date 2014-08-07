require 'turbot_runner'

class Handler < TurbotRunner::BaseHandler
  def initialize(bot_name, config, run_id)
    @bot_name = bot_name
    @config = config
    @run_id = run_id
  end

  def handle_valid_record(record, data_type)
    message = {
      :type => 'bot.record',
      :bot_name => @bot_name,
      :run_id => @run_id,
      :data => record,
      :data_type => data_type,
      :identifying_fields => identifying_fields_for(data_type)

    }
    puts "publishing: #{message}"
#    Hutch.publish('bot.record', message)
  end

  def identifying_fields_for(data_type)
    if data_type == @config['data_type']
      @config['identifying_fields']
    else
      transformers = @config['transformers'].select {|transformer| transformer['data_type'] == data_type}
      raise "Expected to find precisely 1 matching transformer matching #{data_type} in #{@config}" unless transformers.size == 1
      transformers[0]['identifying_fields']
    end
  end
end
