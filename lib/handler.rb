require 'turbot_runner'

class Handler < TurbotRunner::BaseHandler
  attr_reader :ended

  def initialize(bot_name, config, run_id)
    @bot_name = bot_name
    @config = config
    @run_id = run_id
    @ended = false
    @sleep = 1.0 / 40
    @counter = 0
  end

  def handle_valid_record(record, data_type)
    message = {
      :type => 'bot.record',
      :bot_name => @bot_name,
      :snapshot_id => @run_id,
      :data => record,
      :data_type => data_type,
      :identifying_fields => identifying_fields_for(data_type)
    }
    Hutch.publish('bot.record', message)
    sleep @sleep
    @counter += 1

    if @counter > 60 / @sleep
      # Recompute sleep every minute or so
      @counter = 0

      begin
        producer_data = JSON.parse(RestClient.get('http://guest:guest@rabbit1:55672/api/exchanges/%2F/hutch'))
        num_producers = producer_data['incoming'].map {|d| d['stats']['publish_details']}.compact.count{|d| d['rate'] != 0}

        consumer_data = JSON.parse(RestClient.get('http://guest:guest@rabbit1:55672/api/queues'))
        bot_record_consumer_data = consumer_data.detect {|d| d['name'] == 'bot_record_consumer'}
        consumption_rate = bot_record_consumer_data['backing_queue_status']['avg_egress_rate']

        production_rate = consumption_rate / num_producers
        @sleep = 1.0 / production_rate
        puts "New sleep: #{@sleep}"
      rescue Exception => e
        Rails.logger.warn("Hit exception when calculating sleep: #{e}")
      end
    end
  end

  def handle_run_ended
    message = {
      :type => 'run.ended',
      :snapshot_id => @run_id,
      :bot_name => @bot_name
    }
    Hutch.publish('bot.record', message)
    @ended = true
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
