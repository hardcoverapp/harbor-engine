module Harbor
  # Stopping a run from its page or the Runs list.
  #
  # Harbor stops what it runs itself: an agent session (its terminal is
  # closed and the run finished as canceled), and a queued run, which has
  # nothing to kill yet. Anything else a host runs some other way is the
  # host's to stop, through `config.run_stop`; a host with that hook is also
  # handed its queued runs, for whatever bookkeeping it keeps about them.
  module RunStop
    module_function

    # Whether Stop is offered for this run. Never for one `cancelable?` rules
    # out: a finished run, or work with no process behind it.
    def possible?(run)
      return false unless run.cancelable?
      session?(run) || run.pending? || !Harbor.config.run_stop.nil?
    end

    # Stops the run and returns the notice to show. Call only when `possible?`.
    def call(run, user)
      if session?(run)
        Harbor::AgentSession.stop!(run)
        "Stopped run ##{run.id}."
      elsif Harbor.config.run_stop
        Harbor.config.run_stop.call(run, user)
      else
        # The work waiting to start sees the run finished and drops it.
        run.finish!(status: "canceled", error: "canceled while queued")
        "Canceled queued run ##{run.id}."
      end
    end

    # A session under way. A run still waiting has no terminal to close.
    def session?(run) = run.running? && Harbor::AgentSession.session?(run)
  end
end
