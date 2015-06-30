require 'turbot_runner'

class Handler < TurbotRunner::BaseHandler
  attr_reader :ended

  def initialize(bot_name, config, run_id)
    @bot_name = bot_name
    @config = config
    @run_id = run_id
    @ended = false
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
    Hutch.publish(routing_key, message)
    @counter += 1

    if @counter > 1000
      # Every 1000 records, check to see whether the bot_record_consumer queue
      # has grown above a threshold.  If the queue is too big, we sleep for a
      # random amount of time, before checking again.  There may be several
      # other producers, so we want to sleep for a random amount of time so
      # that when the queue size drops below the threshold, each producer gets
      # a chance at being able to continue producing.
      while True
        begin
          tries ||= 3
          consumer_data = JSON.parse(RestClient.get('http://guest:guest@rabbit1:55672/api/queues'))
          num_messages = consumer_data.detect {|d| d['name'] == 'bot_record_consumer'}['messages']
          Rails.logger.info("There are #{num_messages} on the queue")
        rescue => e
          if (tries -= 1) > 0
            Rails.logger.warn("Hit exception when querying rabbitmq: #{e}")
            sleep 10
            retry
          else
            raise
          end
        end

        break if num_messages < 10_000
        sleep Random.rand(10..60)
      end

      @counter = 0
    end
  end

  def handle_run_ended
    message = {
      :type => 'run.ended',
      :snapshot_id => @run_id,
      :bot_name => @bot_name
    }
    Hutch.publish(routing_key, message)
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

  def routing_key
    @run_id == 'draft' ? 'bot.record.draft' : 'bot.record.non-draft'
  end
end
