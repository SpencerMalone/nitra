class Nitra::Master
  attr_reader :configuration, :files, :frameworks, :current_framework

  def initialize(configuration, files = nil)
    @configuration = configuration
    @frameworks = configuration.frameworks
    if @frameworks.any?
      load_files_from_framework_list
    else
      map_files_to_frameworks(files)
    end
    @current_framework = @frameworks.shift
    @configuration.framework = @current_framework
  end

  def run
    return if files_remaining == 0

    progress = Nitra::Progress.new
    progress.file_count = files_remaining
    formatter = Nitra::Formatter.new(progress, configuration)

    runners = []

    if configuration.process_count > 0
      client, runner = Nitra::Channel.pipe
      fork do
        runner.close
        Nitra::Runner.new(configuration, client, "local").run
      end
      client.close
      runners << runner
    end

    slave = Nitra::Slave::Client.new(configuration)
    runners += slave.connect

    formatter.start

    while runners.length > 0
      Nitra::Channel.read_select(runners).each do |channel|
        if data = channel.read
          case data["command"]
          when "next"
            if files_remaining == 0
              channel.write "command" => "drain"
            elsif data["framework"] == current_framework
              channel.write "command" => "file", "filename" => next_file
            else
              channel.write "command" => "framework", "framework" => current_framework
            end

          when "result"
            examples = data["example_count"] || 0
            failures = data["failure_count"] || 0
            failure = data["return_code"].to_i != 0
            progress.file_progress(examples, failures, failure, data["text"])
            formatter.print_progress

          when "error"
            say_lines(data["text"], "#{data["on"]} [ERROR for #{data["process"]}] ")
            formatter.progress
            channel.close
            runners.delete channel

          when "debug"
            say_lines(data["text"], "#{data["on"]} [DEBUG] ") if configuration.debug

          when "stdout"
            say_lines(data["text"], "#{data["on"]} [STDOUT for #{data["process"]}] ") if configuration.debug

          when "stderr"
            say_lines(data["text"], "#{data["on"]} [STDERR for #{data["process"]}] ")

          when "retry"
            say "#{data["on"]} Re-running #{data["filename"]}"

          when "slave_configuration"
            slave_details = slave.slave_details_by_server.fetch(channel)
            slave_config = configuration.dup
            slave_config.process_count = slave_details.fetch(:cpus)

            debug "#{data["on"]} Slave runner configuration requested"
            channel.write(
              "command" => "configuration",
              "configuration" => slave_config)

          else
            say "Unrecognised nitra command to master #{data["command"]}"
          end
        else
          channel.close
          runners.delete channel
        end
      end
    end

    debug "waiting for all children to exit..."
    Process.waitall

    formatter.finish

    !$aborted && progress.files_completed == progress.file_count && progress.failure_count.zero? && !progress.failure
  end

  protected
  def say(text)
    puts text
    $stdout.flush
  end

  def say_lines(text, prefix)
    text.split(/\n/).each {|line| puts "#{prefix}#{line}"}
    $stdout.flush
  end

  def debug(*text)
    say "master: [DEBUG] #{text.join}" if configuration.debug
  end

  def map_files_to_frameworks(files)
    @files = files.group_by do |filename|
     framework_name, framework_class = Nitra::Workers::Worker.worker_classes.find {|framework_name, framework_class| framework_class.filename_match?(filename)}
     framework_name
    end
    @frameworks = @files.keys
  end

  def load_files_from_framework_list
    @files = frameworks.inject({}) do |result, framework_name|
      result[framework_name] = Nitra::Workers::Worker.worker_classes[framework_name].files
      result
    end
  end

  def files_remaining
    files.values.inject(0) {|sum, filenames| sum + filenames.length}
  end

  def current_framework_files
    files[current_framework]
  end

  def next_file
    raise if files_remaining == 0
    file = current_framework_files.shift
    @current_framework = frameworks.shift if current_framework_files.length == 0
    file
  end
end
