# Changelog

## 0.28.1

The pairing-code way of reaching an Orca server (0.25.1) has now been run against a
real one: a second, headless Orca server (`ORCA_SERVE_RUNTIME=orcad`, Orca 1.4.257),
asked for its status, told about a repository, and used to make a worktree, run a
command in a terminal there, close it and remove the worktree, every command carrying
the code and nothing saved on the calling machine. Two things it showed are fixed:

- **A server that doesn't know the repository yet is told about it.** A server that
  has just been started knows none, and `worktree create` answered `repo_not_found`.
  When a runtime names its repository by folder (`"repo": "path:/srv/app"`), Harbor now
  adds that folder to the server (`orca repo add`) and asks again, once. A repository
  named by id or name is not guessed at. `Harbor::Orca::Client#add_repo`.
- **A remote runtime reached by a pairing code passes its health check.** Orca answers
  `host list` only for the machine it is asked on, never through a pairing code, so the
  check no longer asks. For the same reason the runtime form can't list such a server's
  SSH hosts; type the host.

## 0.28.0

- **Conductor Cloud is a kind of runtime.** The "New runtime" page offers a third kind,
  **Conductor Cloud**, beside Orca and Orca (Remote): work runs in a
  [Conductor Cloud](https://www.conductor.build) workspace made for each run from a
  repository. Its fields are the repository's address, the branch a workspace starts
  from and, under Advanced, the name of the environment variable that holds the API key
  (`CONDUCTOR_API_KEY` unless another is named) and the API's address. The key is never
  typed, stored or shown; a runtime whose variable is empty takes no work and says which
  variable. The backend is `Harbor::Runtimes::Backends::ConductorCloud`, registered by
  Harbor as `conductor_cloud`. See README "Conductor Cloud".
- **`Harbor::ConductorCloud::Client`**: a client for Conductor's REST API. A 5xx or a
  network failure is `Unavailable`, a 404 is `NotFound`, both `Error`s. Its user agent
  names Harbor unless a host sets `config.conductor_cloud_user_agent`.
- **`Harbor::ConductorCloud::Models`**: Conductor's model ids and the rule that finds one
  for a model (`claude-opus-5-5` is `opus-5-5-1m`). A model with none is passed over by
  placement. A host adds ids with `config.conductor_cloud_models`.
- **Agent sessions run on a Conductor Cloud runtime**, so a site with no code of its own
  can run an agent automation or a workflow's agent step there. There is no terminal and
  no runner script: making the workspace starts the session on its first message, and a
  job (`Harbor::AgentSession::PollJob`) reads new transcript messages into the same
  recorder an Orca session's output goes through, so the log, events, cost, tokens and
  result are the same. Stop cancels the session, the finisher archives the workspace, the
  run's timeout applies from when the workspace is ready, an outage of Conductor's API is
  waited out, and a restart of the app picks the session up where reading stopped.
  **This path is tested against a stand-in for Conductor's API and has not been run
  against the real service.**
- `Harbor::AgentSession` takes a backend that is not a terminal. Such a backend answers
  the same calls as Orca's and may also answer `session_from(hash)` (what it holds for a
  run), `poll_session(run)` (Harbor asks it, through `PollJob`, instead of waiting for a
  runner), `continues_sessions?` (false drops `resume_session_id`) and `agent_sessions?`
  (false refuses every session). Orca answers none of them and runs as before.
- Two settings, under Runtimes: **Conductor Cloud: seconds between checks** (10) and
  **Conductor Cloud: workspace setup (minutes)** (30).

Upgrading from 0.27:

- Nothing to migrate, and nothing changes for an Orca runtime.
- The "New runtime" page has a third choice. A host that wants it left off registers a
  subclass that answers `offered?` with false.
- **A host that already registers a backend named `conductor_cloud`** keeps its own: a
  host's registration replaces Harbor's. To share Harbor's client, form and model list,
  make that backend a subclass of `Harbor::Runtimes::Backends::ConductorCloud`. Such a
  subclass inherits the session calls too, so Harbor's agent sessions can then be placed
  on its runtimes; a host that drives Conductor its own way there answers
  `agent_sessions?` with false to keep them off. It should also look at what it
  inherits: `unready_reason` now says when the key or the repository is missing, and
  `place` is the repository's name.
- A host whose own code calls `Harbor::AgentSession.session_of(run)` gets the backend's
  own struct for a run on such a backend, not `Orca::Session`.

## 0.27.1

Two things that stopped a new site, found by setting one up and making an agent, a
runtime, a workspace, an automation, a scorer, a review rule and a workflow on its pages:

- **A new site has the model providers Harbor knows.** Nothing made the Anthropic and
  OpenAI rows, so the alias form offered no provider, no alias could be made, and so no
  agent. The Models pages now make any that are missing, switched on
  (`Harbor::ModelProvider.ensure_known!`). A provider that exists is left as it is.
- **An automation saved with no key is given one made from its name**, with a number
  when that is taken, as a runtime is (`Harbor::KeyFromName`). The form said "Key can't
  be blank".

## 0.27.0

- **Harbor's pages look finished in a site with no stylesheet of its own.** The colours
  and component classes its pages are drawn with (`card`, `pill`, `meta`, `display`,
  `field`, `btn-primary`, `btn-quiet`, `chip`, `log-pre`, and the `ink`, `soft`,
  `hairline`, `pale-…` colours) are now defined by Harbor
  (`app/assets/tailwind/harbor/theme.css`, part of the entry file a host already
  imports), and the page beside the side nav has room around it. Before, a new site
  got working pages with no cards, buttons or spacing. Found by setting Harbor up in
  a blank Rails app and opening every page.
- A host changes a colour by setting its token after the import, and a component by
  defining the class: Harbor's are in the base layer, so the host's win. Harbor sets
  no font and nothing on `body`.
- README "Setting up" is brought up to date: the pages are under `/factory`, and the
  check at the end opens Overview and `/factory/settings`.

Upgrading from 0.26:

- A host that already defines these colours and classes sees no change: its own
  definitions win. One that defined only some of them gets Harbor's for the rest.
- A host that sizes `harbor-page` with utilities keeps its sizes. One that gave it
  none gets a top margin of 2.5rem and padding of 1.5rem at the sides and 6rem below.

## 0.26.0

- **Overview is Harbor's**: the section's front page, at the section's own address
  (`/factory`, `harbor.overview_path`), in `Harbor::OverviewController`. A site with no
  code of its own sees one number for each thing Harbor keeps (runs, spend, agents,
  workflows, automations, runtimes, scorers, proposals, review rounds), who does each
  kind of work, what runs it, how long it takes and what it costs, and what changed
  lately, all read from the records when the page is drawn. See README "Overview".
- **Stage notes**: `Harbor::StageNote`, on the table `factory_notes`, which Harbor's
  migration creates; edited in place on Overview (`Harbor::StageNotesController`,
  `/factory/notes/<stage>`) and handed to `config.export` as `factory/notes/<stage>.md`
  on every save.
- **Velocity is Harbor's**: `/factory/velocity` (`harbor.velocity_path`), in
  `Harbor::VelocityController`, over the last 7, 30 or 90 days, 12 weeks or 6 months.
  Three tabs from Harbor's own records: Runs (how many, how they ended, the median time,
  per week, by agent, by task type, by runtime), Spending (the total, per week, by agent,
  by model) and Scorers (each scorer's pass rate and what the judging cost). See README
  "Velocity".
- **Every page of the menu is Harbor's own route now.** The Overview and Velocity entries
  are the engine's (`scope: :harbor`), so a site with no code of its own has the whole
  menu.
- **What a host declares on Overview** (`Harbor::Overview`): `stage` (the stages work
  moves through, in place of the one stage that holds everything), `part` (more lines
  under a stage's "What it runs"), `way_in` and `steer` (the "Ways in" and "How to steer"
  sections), `change_source` (another source for "What changed", or one of Harbor's
  replaced), `tile` (another number in "At a glance"), `section` and `hide_section`.
- **What a host declares on Velocity** (`Harbor::Velocity`): `tab` and `remove_tab`, and
  `tile` (a number in the row at the top of a tab).
- **Places for a host on the pages**: `harbor/overview/_intro` and
  `harbor/velocity/_intro` (the heading in the host's words, and the page's title),
  `harbor/overview/_note_form_hint`, `harbor/velocity/_spending_cards` and
  `harbor/velocity/_runs_cards`.
- `config.markdown`: how the host draws markdown, for stage notes and the steering text.
  Without it they are shown as written.
- `Harbor::Agent.edited_here` (the agents "What changed" lists) and
  `Harbor::Agent#effort_label`; `Harbor::Automation#trigger_data` (what starts an
  automation, as the data a stage's `starts_on` is asked about).
- A Stimulus controller, `harbor--autosubmit`: a form that submits when a control in it
  changes.

Upgrading from 0.25:

- A host that already has the `factory_notes` table keeps it: the migration creates the
  table and its indexes only when they are missing.
- A host that had its own Overview and Velocity pages removes its controllers, views and
  routes for them: a host route at an address Harbor serves is matched first and hides
  Harbor's page. To keep `factory_path` and `velocity_path` working without naming the
  engine, define them with `direct` in the host's routes, as for the other pages.
- A host with a page of its own at `factory_path` or `velocity_path` in Harbor's menu:
  the entries are the engine's routes now (`overview_path`, `velocity_path`), so the
  host's pages are no longer linked.
- A host with no page there gains two entries at the top of the menu. A site that
  doesn't want one switches it off on the Settings page (`page_overview`,
  `page_velocity`).
- A host that redirects an old address to `/factory/notes/…` stops: that is the notes'
  own address now.
- What was the host's on those pages comes back through the declarations above. A host
  whose stage notes belonged to a user sets `c.user_class` (as for workflows); one whose
  notes were markdown sets `c.markdown`.

## 0.25.1

- **An Orca runtime can reach its server by a pairing code**: the runtime's config names
  the environment variable that holds the code (`"pairing_code_env": "ORCA_PAIRING_CODE"`;
  under Advanced on the runtime form), and Harbor sends the code with every `orca` command
  (`--pairing-code`). Nothing is saved on disk, which is what an app in a container needs:
  it has the `orca` command in its image and the code in its environment. The code is
  never stored in the runtime, shown on a page or put in an error. A runtime whose
  variable is empty takes no work and says which variable. It wins over `"environment"`.
  **Checked against Orca 1.4.257's command line only; not yet run against a real remote
  server.**
- `Harbor::Orca::Client.new(pairing_code:)`.

## 0.25.0

- **Review policy is Harbor's**: the records (`Harbor::ReviewRule` and
  `Harbor::ReviewRuleVersion`, `Harbor::ReviewRound` and `Harbor::ReviewCheckRun`,
  `Harbor::ReviewFeedback` and `Harbor::ReviewEscape`, on the `review_*` tables, which
  Harbor's migration creates), what a rule may say (`Harbor::Reviews::RuleDefinition`,
  with its conditions and path globs), a round as one document
  (`Harbor::Reviews::Document`) and the pages (`/factory/reviews`: the policy, a rule's
  page and form with its versions and roll back, a round with its checks, the
  dashboard). A site with no code of its own writes and versions its rules on the page
  and sees a round with its checks once something records one. The menu's Review policy
  entry is Harbor's own route now. See README "Review policy".
- **Harbor does not run reviews yet.** Deciding which rules a pull request owes,
  running the checks and publishing the result stay with the host, which writes rounds
  into these records (README "What a host's review flow does").
- **What a host declares** (`Harbor::Reviews`): `detector` (a risk detector that is its
  own code, which a rule may then name) and `finding_category` (the kinds of finding
  the dashboard lists).
- **What a host configures**: `config.review_rule_class`,
  `config.review_rule_version_class`, `config.review_document_schema`,
  `config.review_pull_request_url` (links to pull requests),
  `config.review_rule_preview` with `config.review_rule_preview_sample` (the Preview
  buttons; absent without it) and `config.review_cost` (the dashboard's "Code review"
  tile; absent without it).
- **Places for a host on the pages**: `harbor/reviews/_round_review` (the review on a
  round's page, in the host's words) and `harbor/shared/_quality_guide` (the guide at
  the top of the policy page).
- Every saved rule version is handed to `config.export` as
  `reviews/<kind>s/<repo>/<key>.json`.

Upgrading from 0.24:

- A host that already has the `review_*` tables keeps them: the migration creates each
  table, index and foreign key only when it is missing.
- A host that had its own review rule, round, check run, feedback and escape models
  makes them Harbor's: `class ReviewRule < Harbor::ReviewRule` (named with
  `c.review_rule_class`) where it adds something, `ReviewRound = Harbor::ReviewRound`
  where it doesn't. A version that belongs to a user is a subclass that declares the
  association and `author_label`, named with `c.review_rule_version_class`.
- A host that had its own review controllers and views removes them, and removes its
  routes under `reviews`: a host route at an address Harbor serves is matched first and
  hides Harbor's page. To keep `reviews_path`, `review_rule_path` and the rest working
  without naming the engine, define them with `direct` in the host's routes, as for the
  Runs, Agents and Automations pages.
- A host with a page of its own at `reviews_path` in Harbor's menu: the entry is the
  engine's route now (`scope: :harbor`), so the host's page is no longer linked.
- A host whose risk rules name a built-in detector declares each one
  (`Harbor::Reviews.detector`), or those rules can no longer be saved.
- A host whose rounds are read as a document under its own schema name sets
  `c.review_document_schema`; unset, the document says `harbor.review/v1`.
- Nothing is linked, previewed or costed until the host says how:
  `c.review_pull_request_url`, `c.review_rule_preview`, `c.review_cost`.

## 0.24.0

- **The Scorers pages are Harbor's**: the list (`/factory/scorers`), a scorer's page with
  its pass rate by week and its last fifty verdicts, and the form that creates and edits
  one, in `Harbor::ScorersController`. The records are `Harbor::Scorer` and
  `Harbor::ScorerResult`, on the tables `scorers` and `scorer_results`.
- **The Proposals pages are Harbor's**: the list by status (`/factory/proposals`), a
  proposal's page with the change line by line and the failed runs behind it, Apply and
  Dismiss, in `Harbor::ProposalsController`. The record is `Harbor::Proposal`, on the
  table `improvement_proposals`. Harbor applies a proposal to an agent's system prompt or
  to one of its documents.
- **A run's page shows its scores**, between its details and its log, with "Score now"
  (`POST /factory/runs/:id/score`); the page refreshes itself while a verdict is pending.
- **The menu's Scorers and Proposals entries are Harbor's own routes.** A site with no
  code of its own gets the pages, the records and the jobs.
- **Jobs**: `Harbor::Scorers::SampleJob` (a finished agent run is offered to the scorers
  that apply, at their sample rate), `Harbor::Scorers::EvaluateJob` (one scorer judges one
  run, as a child run of it) and `Harbor::Proposals::CheckJob` (a scorer's unreviewed
  failures, by agent, are handed over to be drafted from).
- **Harbor does not run the judge or the drafter.** `config.scorer_judge` is called with a
  `Harbor::Scorers::Judgement` and returns the model's final text; `config.proposal_drafter`
  is called with a batch of failures and starts the run that reads them, whose answer goes
  to `Harbor::Proposals::Recorder`. Without them the pages work and nothing is judged or
  drafted: no run is sampled, and a judgement or a check started by hand ends as an error
  naming the setting. See README "Scorers" and "Proposals".
- **`config.scorer_judge_wait`**: how long a pending judgement holds its claim (11
  minutes). **`config.site_name`**: the site's name in the judge's prompt.
- **`config.scorer_class`** and **`config.proposal_class`** (`Harbor.scorer_class`,
  `Harbor.proposal_class`): a host's subclasses. `Scorer.task_types` and `Scorer.draft`
  decide what the form offers and starts with; `proposal.applied_by_name` names who
  applied one.
- **`Harbor::Proposals.register_target`**: a host's own kind of proposal, with what it is
  called and how a drafting run's entry becomes one.
- **Places for a host on the pages**, as partials in its `app/views/harbor/proposals/`:
  `_proposal_badges`, `_show_actions`, `_show_extras` and `_change` (added when they
  exist), and `_intro`, `_index_actions` and `_guide` (replacing Harbor's); and in
  `app/views/harbor/scorers/`, `_self_improvement_note` (replacing Harbor's).
- `Harbor::Run`: `scorer_results`, `scorable?`, `awaiting_verdict?` and `judge_runs`;
  `delegated_runs` leaves out a scorer's judge; a scorable run that finishes is sampled.
- `Harbor::ModelAlias#scorers`: an alias a scorer judges with can't be deleted.
- `harbor/shared/quality_guide` and `harbor/shared/bar_series`, partials a host's own
  pages can render, and the bar chart's hover bubble in Harbor's stylesheet.
- A migration creates `scorers`, `scorer_results` and `improvement_proposals` where they
  don't exist.

Upgrading from 0.23:

- **Run the migration.** In a host that already has the three tables it changes nothing.
- **Delete the host's `/scorers` and `/proposals` routes, controllers and views, and its
  route for scoring a run.** A host route at the same address is matched first and hides
  Harbor's page.
- `scorers_path`, `scorer_path(scorer)`, `new_scorer_path`, `edit_scorer_path(scorer)`,
  `toggle_scorer_path(scorer)`, `proposals_path`, `proposal_path(proposal)`,
  `apply_proposal_path(proposal)`, `dismiss_proposal_path(proposal)` and
  `score_run_path(run)` are the engine's helpers: `harbor.scorer_path(scorer)` from a host
  view. A host with many calls, or other names for them, keeps its names with `direct` in
  its routes. The menu entry for Proposals is `proposals_path`, not
  `improvement_proposals_path`.
- A host's models become subclasses of Harbor's, named in config
  (`c.scorer_class = "Scorer"`, `c.proposal_class = "ImprovementProposal"`), or the
  constant itself (`ScorerResult = Harbor::ScorerResult`). A host's `Run` and `ModelAlias`
  drop their own `scorer_results`, `scorers`, `scorable?`, `awaiting_verdict?`,
  `judge_runs`, the judge exclusion in `delegated_runs` and the sampling callback.
- **Set `c.scorer_judge`**, or nothing is sampled or judged. A host that judged in a job
  of its own moves what ran the model into the hook, and lets Harbor's job make the judge
  run and the result and record the verdict. Set `c.scorer_judge_wait` to what the claim's
  stale window was.
- **Set `c.proposal_drafter`** to what the host's check queued for each batch, and have
  that run hand its answer to `Harbor::Proposals::Recorder.call`.
- A proposal kind beyond `agent_prompt` and `agent_document` is registered
  (`Harbor::Proposals.register_target`) or the record is invalid. What the host's pages
  showed for it moves into the partials above.
- A host test that looked for `[data-controller=poll]` on a run awaiting a verdict looks
  for `[data-controller='harbor--poll']`.
- A host whose runs page showed scores through `harbor/runs/_show_extras` removes them
  from it: Harbor shows them itself, just above that partial.

## 0.23.0

- **Workflows are Harbor's**: the five records (`Harbor::Workflow`, `WorkflowVersion`,
  `WorkflowRun`, `WorkflowStepRun`, `WorkflowWait`, on the tables of those names), the
  definition and its validation, conditions, the run context and its templates, the
  engine with its `AdvanceJob`, the control actions (cancel, approve or reject, run
  again), the visual builder (`harbor--workflow-builder`) and every page:
  `/factory/workflows` with the builder and the reference, and `/factory/workflow_runs`
  with a run's page. A site with no code of its own builds a workflow in the builder,
  starts it and watches its run. The menu's Workflows entry is Harbor's own route now.
- **One registered list of what a workflow is built from** (`Harbor::Workflows`):
  `register_step` (a step type, its form, its outputs and the object that runs it),
  `register_trigger`, `register_data`, `register_setting`, `register_validator` and
  `register_claim`, with `update_step`, `update_trigger`, `remove_step` and
  `remove_trigger` for Harbor's own entries. Validation, the engine, the builder's
  palette and forms and the reference page all read it.
- **Harbor's own step types need no host**: `agent` and `verifier` (the agent runs as an
  agent session, a tracked Run, through `Harbor::Workflows::AgentStepJob`), the `note`
  action, `filter`, `choice`, `loop`, `approval` and `call`; and the `manual` trigger.
  Waiting for an event and making a workspace are not among them: a host registers
  those (README "Workflows" says how a waiting step is built).
- **`Harbor::Workflows.start!`** starts a workflow from host code, with what the run is
  about (`subject:`) and one active run per workflow per subject.
  `Harbor::Workflows.sweep_waits!` times out parked steps.
- **A Run that is a workflow step hands its result back** when it finishes
  (`Harbor::Run`, `Harbor::Workflows::StepCompletion`), whoever ran it.
  `Harbor::Run#workflow_run` and `Harbor::WebhookEvent#workflow_runs` are associations.
- **Config**: `workflow_class`, `workflow_run_class`, `user_class`, `workflow_params`,
  `workflow_starter`, `workflow_subject`, `workflow_manual_start`, `workflow_event_data`,
  `workflow_run_url`, `workflow_run_finished`, `workflow_step_retry` and
  `workflow_run_cancel`. A setting, **Agent step retry (seconds)**.
- **Places for a host on the pages**, as partials in its `app/views/harbor/workflows/`:
  `_intro`, `_switched_off`, `_empty` and `_run_fields` (in place of Harbor's own), and
  `_index_actions`, `_form_extras`, `_versions_note` and `_reference_triggers`.
- The builder's styles are `app/assets/tailwind/harbor/workflows.css`, imported by
  Harbor's stylesheet.

Upgrading from 0.22:

- Run the migrations. A host that already has the five tables keeps them as they are;
  the migration adds only what is missing (on a new site, the tables and the foreign
  key from `runs.workflow_run_id`).
- A host with its own workflow code deletes what moved (the models' bodies, the
  definition, conditions, context, engine, control, catalog, the advance job, both
  controllers, their views, the builder's Stimulus controller and its `.wf-*` styles)
  and keeps what is its own behind the registry and the hooks: its step types and what
  runs them (`register_step … runner:`), its triggers and how a delivery matches one
  (`register_trigger … matches:`), what `trigger.*` holds (`register_data`), and the
  hooks above. A host class kept under an old name is a subclass
  (`class Workflow < Harbor::Workflow`, named in `c.workflow_class`) or, with nothing
  to add, the same class (`WorkflowStepRun = Harbor::WorkflowStepRun`). A job class
  queued under an old name needs that name to still resolve
  (`Workflows::AdvanceJob = Harbor::Workflows::AdvanceJob`).
- A host that ran its own callback when a workflow step's Run finished removes it:
  `Harbor::Run` does that now, and two would finish the step twice.
- **A host's steps are no longer in the engine's `case`**: every leaf type needs a
  `runner:`. A type recorded, not run, in a dry run is the default; `side_effect: false`
  runs it there. A type a dry run stops at says `dry_run_stop:`; a type that keeps a run
  "running" says `working: true`.
- The catalog the builder is given has no `github_actions`: a `multi` field with
  `suggest_from:` carries its own `suggestions:` (`{ value of the other field => [ … ] }`).
  A `workspace` field carries its fixed `options:`, and the type whose steps it lists is
  registered with `makes_workspace: true`. A trigger's starting values are its
  `defaults:`, and what the canvas writes under it its `summary_fields:`.
- Markup: the builder is `data-controller="harbor--workflow-builder"`, with
  `data-harbor--workflow-builder-*` values and targets; the pages' own refresh and
  folding are `harbor--poll` and `harbor--details`. A host test that looked for
  `workflow-builder` or `poll` on these pages looks for those.
- Route helpers are the engine's (`harbor.workflow_path(workflow)`,
  `harbor.workflow_run_path(run)`). A host that wants its old names defines them with
  `direct`, as for runs and agents. Don't keep a host route at an address Harbor serves:
  it would be matched first and hide Harbor's page.

## 0.22.0

- **Automations are Harbor's**: the record (`Harbor::Automation`, on the `automations`
  table, which Harbor's migration creates), the pages (`/factory/automations`: the list,
  the form that makes and edits one, the switch, "Run now" and Delete, in
  `Harbor::AutomationsController`), starting one (`Harbor::Automations::Dispatch`) and
  the tick (`Harbor::Automations::Tick`, and `Harbor::Automations::TickJob` for a site's
  scheduler). A site with no code of its own makes an agent automation on the page, its
  schedule fires it, and it runs as an agent session of its agent
  (`Harbor::Automations::AgentRunJob`). The menu's Automations entry is Harbor's own
  route now. See README "Automations".
- **The tick starts a due automation exactly once**: a compare-and-set on
  `last_scheduled_at`, once for the latest time missed after an outage, and a start that
  raises is handed back for the next tick. Harbor requires no scheduler: a site gives
  whichever it has one entry, every minute.
- **Job automations**: an automation can enqueue one of the site's own job classes
  (`kind: "job"`, with `job_dispatch` `loader`, `skill` or `self`). They are made in
  code. The page never saves `job_class`, `job_dispatch`, `job_input` or `kind`.
- **What a host declares** (`Harbor::Automations`): `category`, `working_folder`,
  `identity`, `label` and `trigger` (a trigger kind the host fires itself).
- **What a host configures**: `config.automation_class`, `config.automation_params`,
  `config.automation_edited` and `config.automation_agent_run` (a host that runs agent
  automations its own way).
- **Places for a host on the pages**, as partials in the host's
  `app/views/harbor/automations/`: `_name_extras`, `_agent_fields`, `_trigger_fields`
  and `_hint`.
- **Setting "Where slash commands are read from"** (`automation_command_ref`,
  `origin/main` by default): the git ref an automation's slash command is read from when
  Harbor runs it as a session.
- `Harbor::Run` has `belongs_to :automation`; the migration adds the index and the
  foreign key on `runs.automation_id` (deleting an automation keeps its runs).
- `fugit` is a dependency (cron expressions).

Upgrading from 0.21:

- **Schedule the tick.** A site that wants scheduled automations gives its scheduler
  one entry, every minute: `Harbor::Automations::TickJob` (README "The tick"). Without
  it nothing is scheduled; "Run now" still works.
- A host that already has an `automations` table keeps it: the migration creates the
  table only when it is missing, and adds the index and foreign key on
  `runs.automation_id` only when they are missing. A host with columns of its own on
  that table subclasses `Harbor::Automation` and names it: `c.automation_class`.
- A host that had its own `AutomationsController`, views and tick removes them, and
  removes its `resources :automations` routes: a host route at an address Harbor serves
  is matched first and hides Harbor's page. To keep `automations_path` and the rest
  working without naming the engine, define them with `direct` in the host's routes, as
  for the Runs and Agents pages.
- A host with a page of its own at `automations_path` in Harbor's menu: the entry is the
  engine's route now (`scope: :harbor`), so the host's page is no longer linked.
- A host whose `Run` class declares `belongs_to :automation` can drop it; Harbor's is
  the same association, on the host's automation class.
- A host that ran agent automations its own way sets `c.automation_agent_run`. Without
  it, agent automations run as Harbor agent sessions.

## 0.21.0

- **The runtime form is two choices, not a backend and its JSON**: "Orca" (work runs on
  this server) and "Orca (Remote)" (Orca on this server does the work on another machine
  it reaches over SSH). Orca asks for a repository, chosen from the ones Orca has. Orca
  (Remote) asks who hosts the machine (DigitalOcean so far), which of Orca's SSH hosts it
  is, and the project. When Orca can't be asked, the values are typed. Setup hooks and a
  paired Orca server are under Advanced. **The remote kind was built against Orca
  1.4.257's commands and has not yet been run against a real remote host.**
- **Nobody types a runtime's key**: it is made from the name, with a number when that is
  taken. The form has no Key or Host field.
- **The Runtimes list is a table**: status (an icon and a word), the runtime with its
  kind and place, in use against its limit, workspaces, last check, and Edit and
  Enable/Disable. Each row is a card on a phone.
- **A runtime has its own page** (`/factory/runtimes/:id/edit`) with its settings, its
  health check and Remove, which the list used to hold in every card.
- `Harbor::Runtimes::Backend`: `offered?`, `choices`, `fields_partial` and
  `settings_from` (class), `label`, `place` and `choice_value` (instance).
  `Harbor::Runtimes.choices` is what the form offers.
- `Harbor::Orca::Client#repos`, `#hosts` and `#projects`, and `#create_worktree` takes
  `project:` and `host:` in place of `repo:`.
- Icons `:ok`, `:warning` and `:off`, and a `harbor--choice` Stimulus controller (one
  choice decides which fields follow).

Upgrading from 0.20:

- A host's backend it doesn't want offered for new runtimes defines
  `def self.offered? = false`. Without that, each registered backend is one more choice
  on the form, with a host label and its config as JSON.
- `POST /factory/runtimes` and the edit form send `runtime[type]` (a choice's value) and
  `runtime[fields][<type>][…]`, not `runtime[backend]` and `runtime[config]`. A `PATCH`
  with single values (`enabled`, `max_concurrent`, `name`, `host`, `config`) works as
  before.
- Removing a runtime that can't be removed, and a health check asked from a runtime's
  page, go back to that page, not the list.
- A host test that looked for a runtime's card on the list (`h2`, the "Save limit" form,
  "Backend config") looks at the table row or the runtime's page now. `[data-runtime]`,
  `[data-busy]` and `[data-health]` are still on the list.

## 0.20.0

- **The Agents pages are Harbor's**: the list (`/factory/agents`) with its Task routing
  and Shared context tabs, an agent's own page, the form that creates and edits one, and
  its avatar (`/factory/agents/:id/avatar`), in `Harbor::AgentsController`; giving a task
  type to an agent (`PATCH /factory/task_assignments/:task_type`) in
  `Harbor::TaskAssignmentsController`. A site with no code of its own gets all of it:
  identity, avatar upload and removal, model alias, workspace, limits, the system prompt,
  documents as rows, tools, default tasks and configuration as JSON, routing over the
  declared task types, and what every agent is told. The list and the routing table are
  cards on a phone. The menu's Agents entry is Harbor's own route now.
- **Places for a host on those pages**, as partials in the host's
  `app/views/harbor/agents/`: `_agent_columns_head` and `_agent_columns` (its own columns
  in the agents table), `_routing_columns_head` and `_routing_columns` (in the routing
  table), `_show_facts` (an agent's page) and `_form_extras` (fields in the form). See
  README "Agents pages".
- **`config.agent_params`**: attributes of the host's agent class the form may save.
- **`config.agent_edited`**: called with (agent, current user) when an agent is saved
  from the form, before it is checked and saved.
- **`config.task_assignment_class`** (`Harbor.task_assignment_class`): the host's
  subclass of `Harbor::TaskAssignment`. Its `compatible_agents(task_type)` decides who the
  routing tab offers and accepts, and the new `refusal(task_type, agent_key)` what the
  page says for anyone else.
- `harbor_agent_avatar(agent, size:)`, in every view: an agent's image, or its initial.
- `Harbor::AgentSetting.editable_key?(key)`: the keys the Shared context tab may write.
- An agent saved from the form needs a model alias.

Upgrading from 0.19:

- **Delete the host's `/agents` and `/task_assignments` routes, controllers and views.**
  A host route at the same address is matched first and hides Harbor's page.
- `agents_path`, `agent_path(agent)`, `new_agent_path`, `edit_agent_path(agent)`,
  `avatar_agent_path(agent)`, `context_agents_path` and `task_assignment_path(type)` are
  the engine's helpers now: `harbor.agent_path(agent)` from a host view. A host with many
  calls keeps the old names with `direct(:agent) { |agent, options| … }` in its routes.
- Move what the host's pages showed beyond Harbor's into the partials above, the
  attributes its form saved into `config.agent_params`, and anything it did to an agent
  on save into `config.agent_edited`.
- A host that subclasses `Harbor::TaskAssignment` names it:
  `c.task_assignment_class = "TaskAssignment"`. Without that the routing tab offers every
  enabled agent.
- The agent form's document rows use Harbor's `harbor--nested-fields` controller; a
  host's own controller for them is no longer needed.

## 0.19.0

- **The Runs pages are Harbor's**: the list (`/factory/runs`), a run's own page
  (`/factory/runs/:id`), the raw stream download (`…/raw`) and Stop (`POST …/stop`),
  in `Harbor::RunsController`. A site with no code of its own gets the whole of both:
  a run's name, status, agent, model, cost, tokens, where it ran, its command, the
  runs it delegated, its events, its live log (which stays on its newest line while
  the run is under way), its error, input and output. Both pages are laid out for a
  phone. The menu's Runs entry is Harbor's own route now.
- **Places for a host on the run's page**, as partials in the host's
  `app/views/harbor/runs/`: `_show_actions` (buttons beside Stop), `_show_meta` (the
  end of the header's first line) and `_show_extras` (sections of its own). A host
  replaces how an agent is shown (`_agent`) and the details card (`_details`) with a
  partial of the same name. See README "Runs pages".
- **`config.run_stop`**: called with (run, current user) to stop a run that isn't an
  agent session. Without it, Stop is offered for sessions and queued runs only.
- `Harbor::Run.for_page(filters)` (what the list holds), `#delegated_runs`,
  `#own_cost_usd` and `#raw_log_file`, each of which a host's run class can override.
- A `harbor--details` Stimulus controller: a `<details>` stays as the reader left it
  while the page morph-refreshes.
- `harbor_run_link` is always a link, and starting a database operation goes to the
  run's page.

Upgrading from 0.18:

- **Delete the host's `/runs` routes for `index`, `show`, `raw` and `stop`, its
  controller actions and its views.** A host route at the same address is matched
  first and hides Harbor's page. Keep the host's own actions under the same prefix:
  `resources :runs, only: [] do member { post :retry } end`.
- `run_path(run)` and `runs_path` are the engine's helpers now: `harbor.run_path(run)`
  from a host view. A host with many calls keeps the old names with
  `direct(:run) { |run, options| … }` in its routes.
- Move what the host's run page showed beyond Harbor's into the partials above, the
  list's filters into `Run.for_page`, and how the host stops its own runs into
  `config.run_stop`.
- A host that defined `own_cost_usd` or `delegated_runs` on its run class: Harbor
  has both now; keep only what differs.

## 0.18.0

- **A session survives a restart, of the app or of Orca.** Before, a session whose
  terminal went away (the machine restarted, Orca was shut down) was finished as an
  `error`, and a session that ended while the app was down lost its result and was
  finished as an `error` ten minutes after the app came back.
  - **An interrupted session is started again where it stopped**, in the worktree it
    already has: `claude --resume <its session>` with a short prompt saying what
    happened, or, for codex and for a session with no conversation yet, the same command
    again, told that an earlier attempt was cut off. Interrupted means its terminal
    went away with no result, its runner was signalled out of a running command when
    Harbor had not stopped it, or the app went down while it was being started. While
    Orca can't be asked it is tried again every minute, for up to six hours. Time spent
    interrupted is not counted against the session's timeout.
    Setting: **Starts after an interruption** (`agent_session_resume_attempts`, 3;
    0 keeps the old behaviour). See README "Restarts and interruptions".
  - **Closing a session's terminal by hand no longer ends it**: that reads as an
    interruption. Stop a session with `stop!` or on the run's page.
  - **The runner outlasts the app.** While Harbor gives no answer the command carries
    on, and its output and result are kept and delivered when Harbor answers again,
    for up to 12 hours (they were given up on after a few seconds). The files fetched
    for a command are removed as soon as it ends. A Harbor that isn't answering yet
    is asked again for a run's files for up to five minutes before the command starts.
  - **The runner says it is there** every half minute while its command prints nothing
    (an empty log post). The silent-runner check goes by that, so a busy agent's
    terminal is no longer asked about, and "nothing for ten minutes" means the runner
    is gone. The idle limit still goes by what the command prints.
  - **`Harbor::AgentSession.recover!`** picks up every running session when the job
    workers start: queues its checks again and starts an interrupted one. Harbor calls
    it itself under Sidekiq; a host on another queue calls it when its workers start.
  - `run!` given a run that is already a session (a job run again after a restart)
    returns it and takes no slots; it used to raise `AlreadyStarted` holding two.
- The Orca backend gained `clear(session)` (close every terminal of the run's worktree)
  and `discard(run)` (remove a worktree by the run's name); a backend of a host's own
  that takes sessions needs both.

## 0.17.1

- **Enforcing an agent's allow list is now a setting, off by default** ("Enforce agents'
  allow lists", under Runs). 0.17.0 enforced it always. Off, a session has every tool
  and the list only says what is approved without asking, as `--allowedTools` has always
  meant; on, the session gets only the built-in tools on the list. A denied tool is
  denied either way.

## 0.17.0

- **An agent's allow list is now enforced for claude.** A session given
  `allowed_tools` (the caller's, or the agent's `tools["allowed"]`) also gets
  `--tools` with the built-in tools on the list, so the others don't exist for it.
  Before, the list was only passed as `--allowedTools`, which with permissions skipped
  (the default mode) restricts nothing: a "read-only" agent could still run Bash. A
  list that was written as "approved without asking" rather than "everything it may
  use" now needs every tool the agent should have. MCP tools are not built in and are
  unaffected.

- **A session's prompt can be a slash command.**
  `Harbor::AgentSession.run!(agent:, slash_command: "/tidy:shelf 12 --fast")` (and
  `start!`) takes, instead of `prompt:`, the name of a prompt kept in the repository
  the agent works in: `/tidy:shelf` is `.claude/commands/tidy/shelf.md`. The file is
  read on the runner machine, as a first step of the agent command: its YAML
  frontmatter is dropped, `$ARGUMENTS` and `$1`..`$9` are filled in, and the result
  is the prompt the CLI is given. `command_ref: "origin/main"` reads the file from
  that git ref instead of the worktree as checked out, so a session working on
  somebody's branch doesn't take its instructions from that branch. A file or ref
  that isn't there ends the run as an error, with one `ERROR:` line saying where it
  was looked for. `runs.command` shows the slash command. See README "Agent sessions".
- The runner fetches one more file for such a session, `arguments`, in place of
  `prompt`: the arguments are never part of a command line.

## 0.16.0

- **Runtimes can be added and removed on the Runtimes page.** "New runtime" takes a name,
  a backend, a limit and the backend's config, with each backend saying what its config
  means (`Backend.config_help`, `.config_example`). A new runtime takes no work until a
  workspace lists it. One that no workspace lists and no run used can be removed.

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
