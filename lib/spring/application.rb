require "set"
require "spring/watcher"

module Spring
  class Application
    attr_reader :manager, :watcher

    def initialize(manager, watcher = Spring.watcher)
      @manager = manager
      @watcher = watcher
      @setup   = Set.new

      # Workaround for GC bug in Ruby 2 which causes segfaults if watcher.to_io
      # instances get dereffed.
      @fds = [manager, watcher.to_io]
    end

    def start
      require Spring.application_root_path.join("config", "application")

      # The test environment has config.cache_classes = true set by default.
      # However, we don't want this to prevent us from performing class reloading,
      # so this gets around that.
      ::Rails::Application.initializer :initialize_dependency_mechanism, group: :all do
        ActiveSupport::Dependencies.mechanism = :load
      end

      # This initializer has issues after we disconnect from the DB, but we don't need it.
      if defined?(ActiveRecord::Base)
        ActiveRecord::Railtie.initializers.delete_if { |i| i.name == "active_record.set_reloader_hooks" }
      end

      require Spring.application_root_path.join("config", "environment")

      ActiveRecord::Base.remove_connection if defined?(ActiveRecord::Base)

      watcher.add loaded_application_features
      watcher.add Spring.gemfile, "#{Spring.gemfile}.lock"
      watcher.add Rails.application.paths["config/initializers"]

      run
    end

    def run
      watcher.start

      loop do
        IO.select(@fds)

        if watcher.stale?
          exit
        else
          serve manager.recv_io(UNIXSocket)
        end
      end
    end

    def serve(client)
      manager.puts

      streams = 3.times.map { client.recv_io }
      args    = JSON.load(client.read(client.gets.to_i))
      command = Spring.command(args.shift)

      setup command

      ActionDispatch::Reloader.cleanup!
      ActionDispatch::Reloader.prepare!

      pid = fork {
        Process.setsid
        [STDOUT, STDERR, STDIN].zip(streams).each { |a, b| a.reopen(b) }
        IGNORE_SIGNALS.each { |sig| trap(sig, "DEFAULT") }

        ActiveRecord::Base.establish_connection if defined?(ActiveRecord::Base)
        ARGV.replace(args)
        srand

        invoke_after_fork_callbacks

        if command.respond_to?(:call)
          command.call
        else
          exec_name = command.exec_name
          gem_name  = command.gem_name if command.respond_to?(:gem_name)

          exec = Gem.bin_path(gem_name || exec_name, exec_name)
          $0 = exec
          load exec
        end
      }

      manager.puts pid

      # Wait in a separate thread so we can run multiple commands at once
      Thread.new {
        _, status = Process.wait2 pid
        streams.each(&:close)
        client.puts(status.exitstatus)
        client.close
      }

    rescue => e
      streams.each(&:close) if streams
      client.puts(1)
      client.close
      raise
    end

    # The command might need to require some files in the
    # main process so that they are cached. For example a test command wants to
    # load the helper file once and have it cached.
    def setup(command)
      return if @setup.include?(command.class)
      @setup << command.class

      if command.respond_to?(:setup)
        command.setup
        watcher.add loaded_application_features # loaded features may have changed
      end
    end

    def invoke_after_fork_callbacks
      Spring.after_fork_callbacks.each do |callback|
        callback.call
      end
    end

    def loaded_application_features
      $LOADED_FEATURES.select { |f| f.start_with?(File.realpath(Rails.root)) }
    end
  end
end
