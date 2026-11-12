# Harbor's settings. Add one here instead of reading a new ENV key; the host
# names the ENV key an existing one used to be read from (`config.env_fallbacks`).
Harbor::Settings.declare :workflows_enabled,
  type: :boolean, default: false, group: "Workflows", label: "Workflows",
  description: "Lets live workflows start from webhooks, claim the flows they replace and act outside this app. " \
               "Off, nothing starts on its own and every run is a dry run."

Harbor::Settings.declare :self_improvement_pull_requests,
  type: :boolean, default: false, group: "Self-improvement", label: "Open pull requests from proposals",
  description: "Lets an approved proposal open a pull request against a repository. " \
               "Off, the attempt is recorded as a skipped run. Proposals to an agent's own prompt and documents are unaffected."

Harbor::Settings.declare :agent_auto_retries,
  type: :integer, default: 3, min: 0, max: 10, group: "Runs", label: "Automatic retries",
  description: "How many times a failed agent run is retried, as a new run each time, before it is left for a person. 0 turns retries off."
