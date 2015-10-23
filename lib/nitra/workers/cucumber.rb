module Nitra::Workers
  class Cucumber < Worker
    def self.filename_match?(filename)
      filename =~ /\.feature/
    end

    def initialize(runner_id, worker_number, configuration)
      super(runner_id, worker_number, configuration)
    end

    def load_environment
      require 'cucumber'

      require 'nitra/ext/cucumber'
    end

    def minimal_file
      <<-EOS
      Feature: cucumber preloading
        Scenario: a fake scenario
      EOS
    end

    def cuke_runtime
      @cuke_runtime ||= ::Cucumber::ResetableRuntime.new  # This runtime gets reused, this is important as it's the part that loads the steps...
    end

    ##
    # Run a Cucumber file.
    #
    def run_file(filename, preloading = false)
      if configuration.split_files && !preloading && !filename.include?(':')
        ENV['BROWSERLESS'] = 'true'
        if(configuration.cuke_profile.nil?)
          run_with_arguments("--no-color", "--require", "features", "--dry-run", filename)
        else
          run_with_arguments("--no-color", "--require", "features", "--dry-run", filename, "-p", configuration.cuke_profile)
        end
        ENV['BROWSERLESS'] = nil

        scenarios = cuke_runtime.scenarios.collect {|scenario| "#{scenario.location.file}:#{scenario.location.line}"}

        {
          "test_count"    => 0,
          "failure_count" => 0,
          "failure"       => false,
          "parts_to_run"  => scenarios,
        }
      else
        begin
        
        if(configuration.cuke_profile.nil?)
          run_with_arguments("--no-color", "--require", "features", filename)
        else
          run_with_arguments("--no-color", "--require", "features", filename, "-p", configuration.cuke_profile)
        end        rescue => e
          puts "Cucumber error'd! Re-running."
          puts e
          puts e.backtrace
          run_file(filename,preloading)
        end
        puts cuke_runtime.failure?
        puts "Attempt number: " + @attempt.to_s
        puts cuke_runtime.failure? && @configuration.exceptions_to_retry && @attempt && @attempt < @configuration.max_attempts && cuke_runtime.send(:summary_report).test_cases.exceptions[0].to_s =~ @configuration.exceptions_to_retry
        if cuke_runtime.failure? && @configuration.exceptions_to_retry && @attempt && @attempt < @configuration.max_attempts && cuke_runtime.send(:summary_report).test_cases.exceptions[0].to_s =~ @configuration.exceptions_to_retry
            puts "test env number: " + ENV['TEST_ENV_NUMBER']
              if(@attempt == (@configuration.max_attempts - 1))
                puts "Enabling screenshots!"
                ENV['SCREENS'] = "true"
                $take_screens = "true"
              end  
              ENV['TEST_ENV_NUMBER'] = ((ENV['TEST_ENV_NUMBER'].to_i % configuration.process_count) + 1).to_s
            puts "new test env number: " + ENV['TEST_ENV_NUMBER']
          raise RetryException
        end

        if m = io.string.match(/(\d+) scenarios?.+$/)
          test_count = m[1].to_i
          if m = io.string.match(/\d+ scenarios? \(.*(\d+) [failed|undefined].*\)/)
            failure_count = m[1].to_i
          else
            failure_count = 0
          end
        else
          test_count = failure_count = 0
        end

        {
          "test_count"    => test_count,
          "failure_count" => failure_count,
          "failure"       => cuke_runtime.failure?,
        }
      end
    end

    def clean_up

      super

      cuke_runtime.reset
    end

    def run_with_arguments(*args)
      cuke_config = ::Cucumber::Cli::Configuration.new(io, io)
      cuke_config.parse!(args)
      cuke_runtime.configure(cuke_config)
      cuke_runtime.run!
    end
  end
end
