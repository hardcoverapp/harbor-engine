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

Harbor::Settings.declare :model_catalog_url,
  type: :string, default: "https://models.dev/api.json", group: "Models", label: "Model catalog",
  description: "Where the list of each provider's models is read from when picking one for an alias. " \
               "A public catalog in the models.dev format; no API key is used. It is read again every 12 hours."

Harbor::Settings.declare :runner_url,
  type: :string, default: "", group: "Runtimes", label: "Runner address",
  description: "Where work running on another machine reaches this app to send its log and result: the app's public address " \
               "(https://…), with the path Harbor is mounted at when that isn't the root. Runs can't be placed on Orca until this is set."

# Databases: backups and staging refreshes (Harbor::DbOps). Where dumps go and
# what is run are `Harbor.config` values, set on the machine; these are the
# numbers and the one switch.
Harbor::Settings.declare :database_staging_restores,
  type: :boolean, default: false, group: "Databases", label: "Staging restores",
  description: "Lets a staging database be replaced with a saved masked backup, from the Databases page or on a schedule. " \
               "Off, every restore is refused and scheduled refreshes are skipped. Backups are unaffected."

Harbor::Settings.declare :database_backups_kept,
  type: :integer, default: 4, min: 1, max: 365, group: "Databases", label: "Backups kept",
  description: "How many of the newest backups are kept for each database and kind, in the backup folder and in each bucket. Older ones are deleted after a backup."

Harbor::Settings.declare :database_backup_jobs,
  type: :integer, default: 2, min: 1, max: 32, group: "Databases", label: "Parallel dump jobs",
  description: "How many tables a backup dumps at once. More is faster and asks more of the database being read."

Harbor::Settings.declare :database_backup_min_free_gb,
  type: :integer, default: 40, min: 0, group: "Databases", label: "Free space needed (GB)",
  description: "A backup is refused when the backup folder's disk has less than this much free."

Harbor::Settings.declare :database_max_source_age_days,
  type: :integer, default: 7, min: 1, group: "Databases", label: "Newest write allowed (days)",
  description: "A database whose newest row in its freshness tables is older than this is not backed up: " \
               "one that stopped receiving writes is usually a fork or a retired server, not the live one."

Harbor::Settings.declare :database_max_backup_age_days,
  type: :integer, default: 8, min: 1, group: "Databases", label: "Oldest backup a refresh uses (days)",
  description: "A scheduled staging refresh is refused when a database's newest masked backup is older than this."

Harbor::Settings.declare :database_connect_timeout,
  type: :integer, default: 15, min: 1, max: 600, group: "Databases", label: "Connection timeout (seconds)",
  description: "How long a backup or restore waits for a database to answer before failing."

Harbor::Settings.declare :database_upload_threads,
  type: :integer, default: 4, min: 1, max: 64, group: "Databases", label: "Upload threads",
  description: "How many parts of a large file are uploaded to a bucket at once."

# One switch per page of the menu (Harbor::Pages), on by default.
Harbor::Nav::DEFAULTS.each do |label, _route, options|
  Harbor::Pages.declare(options[:key], label: label) if options[:key]
end
