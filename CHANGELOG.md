# Changelog

## 0.15.1

- `Harbor::AgentSession.run!` takes `workspace:`, to place a session on a workspace other
  than the agent's own.

## 0.15.0

- **Agent sessions**: `Harbor::AgentSession.run!(agent:, prompt:)` runs an agent's
  command line (`claude -p`, or `codex exec` for an OpenAI model) as a command in an
  Orca terminal, with only HTTP between the runner and the app, and records what comes
  back: the raw stream beside the live log, a readable line and a `run_events` row per
  event as they arrive, and at the end the session id, model, cost, duration, tokens,
  final text and status. `start!` is the same for a host that places the run itself;
  `stop!` cancels one. See README "Agent sessions".
- Hooks: `c.agent_session_env` (the command's environment, where secrets come from),
  `c.agent_session_preamble`, `c.agent_session_finished`, `c.claude_bin`, `c.codex_bin`.
  Setting: **Silent runner check (minutes)** (`agent_session_silent_minutes`, 10).
- Secrets reach the command in a file the runner fetches and sources
  (`POST /harbor/runner/runs/:id/bundle/:name`), never on a command line; every session
  runs with `--strict-mcp-config` and an MCP config of its own.
- Timeouts as Active Job jobs (`Harbor::AgentSession::WatchJob`): a whole-session limit,
  an optional idle limit, and a check that finishes a session whose runner stopped
  reporting and whose terminal has gone.
- **Runner protocol v2**, for every run on Orca:
  - Each log post says where it starts (`?offset=N`). A post sent twice adds nothing
    twice; one that would leave a gap is answered `409` with Harbor's count and the
    script resumes from it. Before, a retried post duplicated its bytes.
  - No post is over 1 MB, so a backlog drains in pieces. Before, a backlog over the
    2 MB limit was refused forever and the log stalled.
  - Bytes are kept as they arrive and made valid text only where they are read
    (`Harbor::LiveLog.read` and `.tail`). Before, a character split across two posts
    was corrupted.
  - The script traps TERM, HUP and INT: it stops the command's whole process group
    (TERM, then KILL), sends what was printed and a result with `"signalled": true`,
    and removes its files. Before, a closed terminal reported nothing.
  - The command runs in a group of its own, with a private `$HARBOR_RUN_DIR`, and is no
    longer given the run's token in its environment.
  - A result is taken once: `c.run_reported` is no longer called for a second report or
    for a run that is already finished. What was reported is in
    `run.runner_state` (`exit_status`, `signalled`).
- `runs.runner_state` (jsonb): what Harbor keeps about a run's runner.
- The Orca backend enforces tool rules (`enforces_tool_policy?`), and is not chosen for
  an OpenAI model when the agent's rules are ones `codex` can't keep. It gains
  `restart(session, …)` and `exited?(session)`; `start` passes `bundle:` and `attempt:`
  on to `Harbor::Runner.command_for`.
- `Harbor::Orca.runner`: what runs the `orca` command for clients not given their own
  (tests set a stand-in).
- A run with only an `agent_key` now has a live log, named for the agent.

Upgrading from 0.14.0 or 0.14.1:

- Run the migrations: `runs.runner_state` is added (`if_not_exists`, default `{}`).
- Let `POST /harbor/runner/runs/:id/bundle/:name` through whatever is in front of the
  app. A rule that already allows `POST` under `/harbor/runner/` covers it.
- A run started before the upgrade keeps working: its script posts without an offset,
  which is taken as the next piece. Runs started afterwards use offsets.
- `c.run_reported` hosts: the hook is now called at most once per run and not at all
  for a finished run. Read `run.runner_state["signalled"]` to tell a stopped command
  from one that failed.
- A host backend used for agent sessions must answer `start`, `restart`, `stop`,
  `cleanup` and `exited?`. Harbor's Orca backend does.
- Agent sessions need an Active Job queue that honours `set(wait:)`, for timeouts.
- If the host's `c.log_path` is its own, nothing changes; with the default, runs that
  have an `agent_key` and neither `loader` nor `skill` now get a log file.

## 0.14.1

- **The Webhooks page reads properly on a phone.** A delivery is three short lines
  (what came in and its status, what it was about, then what it started and when), and
  nothing overlaps or runs off the side. From tablet width up it is laid out as before.

## 0.14.0

- **Every page is under `/factory`**: `/factory/runtimes`, `/factory/databases`,
  `/factory/settings` and so on. `path:` in `config/harbor.yml` changes it (`path: /ops`,
  or `path: /` for the root); it is read when routes are drawn, so a change takes a
  restart. `Harbor.path` is the value, for a host that keeps pages of the section in its
  own routes (`scope Harbor.path do … end`).
- The runner endpoints stay at `/harbor/runner/`, whatever the path is.
- A nav item's `also:` prefixes are written without the section's path.

Upgrading from 0.13.0: the engine is still mounted at `/`. Links built with route
helpers follow by themselves; a hard-coded `/runtimes` or `/settings` needs the path, or
set `path: /` to keep the old addresses.

## 0.13.0

- **`config/harbor.yml`**, one config file in the host (run through ERB, then YAML;
  `c.config_file` names another path). It declares the databases and the restore
  environments, naming ENV keys and never URLs. A missing file declares nothing;
  anything invalid in it is a `Harbor::Databases::Error` naming the file and the entry,
  logged at boot, shown on the page and raised by every operation.
- **Restore environments** replace the single staging copy per database. An environment
  is a named list of restores (database, backup kind, `target_env`) with its own switch:
  `enabled: true` or `enabled_env:` naming an ENV key that must be exactly `true`. One
  database may feed several environments, and an environment may take several
  databases. `backup: full` restores a full dump; nothing else ever does.
- **A target is replaceable only because the file lists it** in an environment the file
  has switched on. No check looks at what a database or host is called any more.
- The **Environments** tab on the Databases page; `Harbor::EnvironmentRestoreJob`;
  `Harbor::DbOps::Environment`, `RestoreEntry` and `EnvironmentRestore`.
- Two URLs are now also the same database when they differ only by a trailing dot on
  the host or by which name they use for this machine, and Rails's own databases are
  matched without case.

Upgrading from 0.12.0:

- `Harbor::Databases.declare(staging_env:)` is gone and raises. Move each staging URL to
  a restore in `config/harbor.yml`:
  `restore_environments: { staging: { enabled_env: …, restores: [ { database: …, target_env: … } ] } }`.
  Databases may move to the file too, or stay in Ruby.
- `c.staging_restores_env` is gone. Name the same ENV key as the environment's
  `enabled_env`. With no environment declared, nothing is restored.
- `c.unsafe_restore_env` and the rule it overrode are gone: a target no longer has to
  have `staging` in its name or host, and `HARBOR_ALLOW_UNSAFE_RESTORE` is not read.
  Check that every `target_env` in the file is a database you mean to replace.
- `config.database_operation` is called with `"<environment key>-restore"` and
  `input: { environment: }` for a whole environment (`"staging-restore"` for one keyed
  `staging`, as before), and `"database-restore"` now carries `environment:` in its
  input. `Harbor::DatabaseRestoreJob` refuses a run whose input names no environment.
- The page's `POST /databases/refresh_staging` is now
  `POST /databases/environments/:environment/restore`, and `POST /databases/:id/restore`
  needs an `environment` param.
- `Harbor::DbOps::Database#staging`, `#staging_env`, `#staging_configured?`,
  `#staging_variant`, `#validate_staging!`, `#validate_disposable!` and
  `.staging_restores_enabled?` are gone: use `Database#restore_in(key)` and
  `Harbor::DbOps::Environment`. `Restore#preflight` and `#apply` take a `RestoreEntry`
  where they took a database. `Target#assert_safe_to_destroy!` is
  `Target#assert_distinct_from!(protected)`.

## 0.12.0

- **Databases** (`/databases`): backups of the databases a host declares and refreshes
  of their staging copies, with the Databases page, its switch and its menu entry.
  `Harbor::DbOps::*` does the work and `Harbor::DatabaseBackup` is the catalog
  (`database_backups`).
- **`Harbor::Databases.declare`** names each database's ENV keys (its URLs stay in ENV),
  its freshness tables and whether it is the app's own; `declare_each_time` for a list
  read when asked for.
- Greenmask, the PostgreSQL and MySQL client tools and the `aws-sdk-s3` gem are needed
  only when a backup or restore runs. With no database declared the page says so.
- Config, set on the machine: `backup_root`, `backup_host_root`, `masking_rules_path`,
  `greenmask_bin`, `greenmask_pg_bin_path`, `backup_bucket_env_prefix`,
  `staging_restores_env`, `unsafe_restore_env`, `staging_lock_role`, `restore_application_name`,
  `restore_spared_applications`, `backup_kind_notes`.
- Staging restores are allowed only by an ENV key on the machine
  (`staging_restores_env`), never by a setting.
- Settings, under Databases: backups kept, parallel
  dump jobs, free space needed, newest write allowed, oldest backup a refresh uses,
  connection timeout, upload threads.
- **`Harbor::TrackedJob`**, a job whose life is one run, and `config.tracked_job` for a
  host with its own. `Harbor::DbOperationJob` and `Harbor::DatabaseRestoreJob` are built
  on it; `config.database_operation` starts an operation from the page and
  `config.database_schedule` says when one next runs.
- The run progress bar is `harbor/shared/run_progress`.

## 0.11.0

- **The Models page** (`/models`): a Models tab with each provider's usage and switch,
  and an Aliases tab listing each alias's models in order.
- **The alias form** (`/model_aliases/new`, `/model_aliases/:id/edit`): models picked
  per provider from `Harbor::ModelCatalog`, with backups added and reordered in place.
- `config.refresh_model_usage` puts a "Refresh usage" button on the page and does the
  reading; `config.model_name` says how a model id reads to a person.
- A provider's switch and an alias edit call `config.availability_changed`.
- Stimulus controller `harbor--model-picker`.
- The menu's Models entry now points at Harbor's page.

## 0.10.0

- **The Runtimes page** (`/runtimes`): each runtime's limit, live busy count and health,
  with its switch, a health check and its backend config.
- **The Workspaces pages** (`/workspaces`): the ordered lists of runtimes, created,
  reordered and deleted in the app.
- `config.availability_changed` is told when a runtime or workspace changes, so a host
  with work waiting for somewhere to run looks again.
- Stimulus controllers `harbor--nested-fields` and `harbor--poll`.
- The menu's Runtimes and Workspaces entries now point at Harbor's pages.

## 0.9.0

- **The Orca backend** (`Harbor::Runtimes::Backends::Orca`, registered as `orca`): a
  run is a command in a terminal of a worktree on an Orca server, local or paired. The
  runtime's config names the repo, the environment and whether setup hooks run.
- **`Harbor::Runner`**: the command is wrapped in a small sh script that posts its
  output and exit status back, so no disk is shared with the runner. The new **Runner
  address** setting says where runners reach the app.
- **Runner endpoints** under `/harbor/runner/`: `POST runs/:id/log` and
  `POST runs/:id/result`, with no login, each request carrying the run's own token
  (`Harbor::RunToken`). `config.run_reported` is told when a run's command ends.
- `Harbor::LiveLog.append` adds output that arrives in pieces.

## 0.8.0

- **`Harbor::Runtime`, `Harbor::WorkspaceProfile` and `Harbor::WorkspaceProfileRuntime`**:
  the places work runs and the ordered lists of them that agents pick.
  `config.runtime_class` and `config.workspace_profile_class` for a host's subclasses.
- **`Harbor::Runtimes::Backend`** and **`Harbor::Runtimes.register`**: the code behind a
  runtime, registered by name, so a host adds its own.
- **`Harbor::Runtimes::Placement`**: chooses a runtime and a model together, walking the
  workspace's list. `config.sticky_runtime` sends follow-up work back to the runtime
  holding its workspace.
- **`Harbor::Slots`** and **`Harbor::Runtimes::Slots`**: atomic capacity leases in Redis
  (`config.redis`, `config.slot_key`), per agent and per runtime.
- **`Harbor::Agent`** gains its workspace, its limits (`max_agents`, `max_workspaces`),
  `placement` and `model_choice_for`.
- **`Harbor::Orca::Client`**: worktrees and terminals on an Orca server, the one beside
  Harbor or a paired one, through the `orca` command line (`config.orca_bin`). Not used
  by a backend yet.
- `ModelAlias#resolve` raises the class's own `Unavailable`, so a host's subclass can
  keep its own error name.

## 0.7.0

- **`Harbor::Agent`, `Harbor::AgentDocument` and `Harbor::AgentSetting`**: an agent's
  identity, instructions, documents, tools, avatar and model alias, and the house
  context and shared documents every agent is given. `config.agent_class` for a host's
  subclass.
- **`Harbor::TaskAssignment` and `Harbor::TaskTypes`**: which agent handles which kind
  of work. The host declares its task types (with an optional fallback type and default
  agent); assignments are rows edited in the app.
- The migration creates `agents`, `agent_documents`, `agent_settings` and
  `task_assignments`, or leaves them alone where they exist.

## 0.6.1

- **Fix:** associations to a class the host names (`run_event.run`,
  `webhook_event.run`, `model_choice.model_alias`) returned Harbor's own class instead
  of a host's subclass with the same short name (`Run` was found as `Harbor::Run`).
  They now use the configured class.

## 0.6.0

- **`Harbor::ModelProvider`, `Harbor::ModelAlias` and `Harbor::ModelChoice`**: the
  providers agents' models come from, and the named, ordered lists of models agents are
  given. `config.model_alias_class` for a host's subclass. The migration creates the
  three tables, or leaves them alone where they exist.
- **`Harbor::ModelCatalog`**: each provider's models, read from a public catalog
  (the `model_catalog_url` setting, models.dev by default) with no API key, newest
  first, refreshed every 12 hours and kept when a refresh fails.

## 0.5.0

- **`Harbor::WebhookEvent`** and **the Webhooks page** (`/webhooks`): every inbound
  delivery and what it started. `config.webhook_event_class` for a host's subclass; an
  optional `harbor/webhooks/_event_extras` partial for what a host adds per delivery.
  The menu's Webhooks entry now points at Harbor's page.
- **`harbor_status_pill`**, one look for a status wherever it shows, and
  **`harbor_run_link`**, which links a run to its page wherever that page lives.
- Harbor's controllers include `Harbor::PageGate` themselves.

## 0.4.0

- **`Harbor::LiveLog`**: open, append to and close a run's live log; read it, or just
  its tail. `Harbor::Run#live_log_path` names each run's log.
- **`config.log_location` and `config.log_path`**: where logs are kept and what each is
  called. The default is `storage/harbor/logs/<kind>/run-<id>.log`.

## 0.3.0

- **`Harbor::Run` and `Harbor::RunEvent`**: the record of every piece of background
  work, and the parsed events of an agent run. The migration creates `runs` and
  `run_events`, or leaves them alone where they exist.
- **`config.run_class`**: a host's subclass of `Harbor::Run`, for what is the host's
  own. `Harbor.run_class` is the class Harbor uses.

## 0.2.0

The section's look becomes Harbor's own.

- **A side nav** beside every page of the section: pages grouped under headings, each
  with an icon, collapsible to a rail of icons that the browser remembers. It replaces
  the row of tabs (`harbor/shared/_tabs` is gone).
- **A shell** for the host's layout: `harbor_section?`, `yield :harbor_nav`, and the
  `harbor-shell` / `harbor-aside` / `harbor-page` classes. A host page joins the section
  with `render "harbor/shared/section_nav"`.
- **Menu entries carry a group and an icon**: `nav.add ..., group:, icon:`.
  `harbor_nav_groups` gives the menu by group; `harbor_icon` draws an icon.
- **A theme**: every colour and size of the side nav is a `--harbor-nav-*` CSS variable
  a host can override.
- **Page tabs** for a page's own sub-pages: `harbor/shared/_page_tabs`.
- **Two Stimulus controllers**, pinned into the host's import map: `harbor--side-nav`
  and `harbor--log-follow`.
- Workflows is the current page on `/workflow_runs` too.
- Harbor's styles now ship in its Tailwind entry file; the README says not to link that
  file as a stylesheet.

Upgrading from 0.1.0: replace `render "harbor/shared/tabs"` with
`render "harbor/shared/section_nav"`, add the shell and `harbor_nav_state_tag` to the
layout, and note that the menu's order is now by group.

## 0.1.0

The foundation.

- `Harbor.nav`: the one list behind a host's section menu and the tabs above each page.
- Settings: declared in code, saved in `harbor_settings`, edited on `/settings`. A saved
  value wins, then the host's ENV fallback, then the default.
- Three settings: the workflows switch, opening pull requests from proposals, and the
  automatic retry count.
- Pages inherit the host's base controller for login, layout and current user.
- A Tailwind entry point (`app/assets/tailwind/harbor/engine.css`) so a host's build
  reads Harbor's views.
- The menu lists only the entries whose page exists in the host.
- Every page of the menu except Settings can be switched off on the Settings page:
  it leaves the menu, and a controller that includes `Harbor::PageGate` answers as not
  found. A host's own page gets a switch with `nav.add ..., key:`.
