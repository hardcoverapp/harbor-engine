require "shellwords"

module Harbor
  # How work that runs somewhere else reports to Harbor. A run placed on
  # another machine is a command wrapped in a small script (harbor-runner.sh)
  # that posts the command's output and exit status back over HTTPS, signed
  # with a token good for that run only. No disk is shared with the runner.
  module Runner
    SCRIPT = File.read(File.expand_path("runner/harbor-runner.sh", __dir__)).freeze

    class NoAddress < StandardError; end

    module_function

    # Where runners reach this app: the "Runner address" setting.
    def base_url = Harbor::Setting.get(:runner_url).to_s.strip.chomp("/")

    def configured? = base_url.match?(%r{\Ahttps?://})

    # A run's address for its runner.
    def url_for(run)
      raise NoAddress, "Set the runner address on the Settings page: where runners reach this app." unless configured?
      "#{base_url}/harbor/runner/runs/#{run.id}"
    end

    # The shell line that runs `command` for `run` and reports back. It
    # carries the script itself, so the runner machine needs nothing installed
    # but sh and curl.
    def command_for(run, command)
      env = { "HARBOR_RUNNER_URL" => url_for(run), "HARBOR_RUNNER_TOKEN" => Harbor::RunToken.generate(run) }
      assignments = env.map { |key, value| "#{key}=#{Shellwords.escape(value)}" }.join(" ")
      "#{assignments} sh -c #{Shellwords.escape(SCRIPT)} harbor-runner #{Shellwords.escape(command)}"
    end
  end
end
