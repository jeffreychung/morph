module Morph
  class DockerRunner
    def self.run(options)
      wrapper = Multiblock.wrapper
      yield(wrapper)

      # Open up a special interactive connection to Docker
      # TODO Cache connection
      conn_interactive = Docker::Connection.new(ENV["DOCKER_URL"] || Docker.default_socket_url, {chunk_size: 1, read_timeout: 4.hours})
      local_root_path = ENV['DOCKER_URL'] ? "/vagrant" : Rails.root
      command = options[:command]
      # This will fail if there is another container with the same name
      begin
        docker_args = {"Cmd" => ['/bin/bash', '-l', '-c', command],
          "User" => "scraper",
          "Image" => options[:image_name],
          "name" => options[:container_name],
          # See explanation in https://github.com/openaustralia/morph/issues/242
          "CpuShares" => 307,
          # Memory limit (in bytes)
          # On a 1G machine we're allowing a max of 10 containers to run at a time. So, 100M
          "Memory" => 100 * 1024 * 1024,
          "Env" => ["TURBOT_API_KEY=#{ENV['TURBOT_API_KEY']}", "MORPH_URL=#{ENV['MORPH_URL']}"]}
        puts "Creating container #{docker_args}"
        c = Docker::Container.create(docker_args, conn_interactive)
      rescue Excon::Errors::SocketError => e
        wrapper.call(:log, :internal, "Morph internal error: Could not connect to Docker server: #{e}\n")
        wrapper.call(:log, :internal, "Requeueing...\n")
        raise "Could not connect to Docker server: #{e}"
      end

      # TODO the local path will be different if docker isn't running through Vagrant (i.e. locally)
      # When using vagrant we use a hard coded end point so it has the correct permissions
      begin
        c.start("Binds" => [
          "#{local_root_path}/#{options[:repo_path]}:/repo:ro",
          "#{local_root_path}/#{options[:data_path]}:/data",
          "#{local_root_path}/utils:/utils:ro"
        ])
        puts "Running docker container..."
        # Let parent know about ip address of running container
        wrapper.call(:ip_address, c.json["NetworkSettings"]["IPAddress"])
        puts "Local root path :#{local_root_path}"
        puts "Calling /bin/bash -l -c #{options[:command]} in directory /data..."
        c.attach(logs: true) do |stream,chunk|
          wrapper.call(:log, stream, chunk)
        end
        status_code = c.json["State"]["ExitCode"]
        puts "Docker container finished..."
      rescue Exception => e
        wrapper.call(:log,  :internal, "Morph internal error: #{e}\n")
        wrapper.call(:log, :internal, "Stopping current container and requeueing\n")
        c.kill
        raise e
      ensure
        # Wait until container has definitely stopped
        c.wait
        # Clean up after ourselves
        c.delete
      end

      status_code
    end

    def self.container_exists?(name)
      begin
        Docker::Container.get(name)
        true
      rescue Docker::Error::NotFoundError => e
        false
      end
    end
  end
end
