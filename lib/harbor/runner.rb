require "shellwords"

module Harbor
  # How work that runs somewhere else reports to Harbor. A run placed on
  # another machine is a command wrapped in a small script (harbor-runner.sh)
  # that posts the command's output and exit status back over HTTPS, signed
  # with a token good for that run only. No disk is shared with the runner.
  # What the endpoints do with a post is Harbor::RunnerReport.
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
    #
    # `bundle` names the run's files the script fetches before the command
    # starts (Harbor::Runner::RunsController#bundle); `attempt` says which
    # start of the run this is, so a report from an earlier one is ignored.
    # Nothing here is secret but the run's own token.
    def command_for(run, command, bundle: nil, attempt: nil)
      env = { "HARBOR_RUNNER_URL" => url_for(run), "HARBOR_RUNNER_TOKEN" => Harbor::RunToken.generate(run) }
      env["HARBOR_RUNNER_BUNDLE"] = Array(bundle).join(" ") if bundle.present?
      env["HARBOR_RUNNER_ATTEMPT"] = attempt.to_s if attempt
      assignments = env.map { |key, value| "#{key}=#{Shellwords.escape(value)}" }.join(" ")
      "#{assignments} sh -c #{Shellwords.escape(SCRIPT)} harbor-runner #{Shellwords.escape(command)}"
    end
  end
end
