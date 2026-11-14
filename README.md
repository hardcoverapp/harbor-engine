# Harbor

A software factory for Rails apps: a mountable engine that runs agent work.
Workflows whose steps are runs, placed on runtimes through workspaces, executed
by agents with routed models, judged by scorers, improved through proposals,
and triggered by webhooks and schedules.

Harbor is being extracted from Hardcover's internal app, one area at a time.
**It is early.** Today the engine holds the foundation: the section menu, the
settings system and the Settings page. The rest arrives as it is cut free of
the app it came from.

## Setting up

Harbor needs a Rails 8.1+ app on Postgres with a login of its own. It has no
login: its pages are exactly as protected as the controller you give it.

### 1. Add the gem

The gem is `harbor-engine` (the code's namespace is `Harbor`). It is not on
RubyGems yet; add it from this repository, pinned to a release tag:

```ruby
# Gemfile
gem "harbor-engine", github: "hardcoverapp/harbor-engine", tag: "v0.5.0"
```

```bash
bundle install
```

### 2. Mount it

Mount Harbor last in the host's routes, so the host's own routes win:

```ruby
# config/routes.rb
mount Harbor::Engine => "/", as: :harbor
```

Harbor's pages then live at the root (`/settings`). Mount it somewhere else
(`=> "/harbor"`) if the host already uses those paths.

### 3. Migrate

Harbor's migrations run with the host's; nothing is copied into `db/migrate`.

```bash
bin/rails db:migrate
```

### 4. Give it a login and a layout

Harbor's pages inherit one of the host's controllers, and with it the host's
login check, layout and current user. The default is `ApplicationController`.

```ruby
# config/initializers/harbor.rb
Harbor.configure do |c|
  c.parent_controller = "ApplicationController"
end
```

**That controller must refuse people who aren't logged in.** If it has no
login check, anyone who can reach the app can change Harbor's settings. Point
`parent_controller` at an admin-only controller if only some users should.

Two things the controller and its layout need:

- A `current_user` method (private is fine), if you want Harbor to record who
  changed a setting.
- Links to the host's own pages that work from inside an engine. In a
  `before_action` or `redirect_to` in that controller, write
  `main_app.login_path`, not a bare `login_path`. Links in the layout need no
  change.

### 5. Draw the section

Harbor draws its pages inside a shell: a side nav down the left, the page
beside it. The layout is the host's, so the host adds three things to it.

In `<head>`, so a collapsed side nav doesn't open and snap shut on every page:

```erb
<%= harbor_nav_state_tag %>
```

Around the page, the shell (only on pages of Harbor's section):

```erb
<% if harbor_section? %>
  <main class="harbor-shell">
    <aside class="harbor-aside"><%= yield :harbor_nav %></aside>
    <div class="harbor-page"><%= yield %></div>
  </main>
<% else %>
  <main><%= yield %></main>
<% end %>
```

And, if the host has a menu of its own, Harbor's pages in it:

```erb
<% harbor_nav_groups.each do |group| %>
  <%= group.heading %>
  <% group.links.each do |link| %>
    <%= link_to link.path do %><%= harbor_icon(link.icon) %> <%= link.label %><% end %>
  <% end %>
<% end %>
```

The side nav lists only the pages that exist in the host, in groups (Flows,
Activity, Agents, Infrastructure, Quality), each with an icon. It collapses to
a rail of icons and remembers that in the browser. Below 768px it is hidden;
list the pages in the host's own mobile menu.

A page of the host's joins the section by rendering the side nav first, and
the menu by being added to it:

```erb
<%= render "harbor/shared/section_nav" %>
```

```ruby
Harbor.configure do |c|
  c.nav.add "Storage", :storage_path, group: :infrastructure, icon: :database, key: :storage
end
```

`group:` is one of Harbor's (`:overview`, `:flows`, `:activity`, `:agents`,
`:infrastructure`, `:quality`) or a name of the host's own, which becomes a
group after Harbor's. `icon:` is a name from `Harbor::Icons::PATHS` or SVG
markup. A page's own sub-pages get tabs:

```erb
<%= render "harbor/shared/page_tabs", label: "Reports",
      tabs: [ [ "Monthly", monthly_reports_path, true ], [ "Yearly", yearly_reports_path, false ] ] %>
```

### 6. Styles and JavaScript

Harbor's styles ship as a Tailwind entry file. A host that builds its CSS with
`tailwindcss-rails` adds one line to its `app/assets/tailwind/application.css`:

```css
@import "../builds/tailwind/harbor";
```

`tailwindcss-rails` writes that file during its build. It brings the shell,
the side nav and the tabs, and makes Tailwind read Harbor's views.

**Don't link that entry file as a stylesheet.** It sits under
`app/assets/builds`, so `stylesheet_link_tag :app` links it, and all it holds
is an `@import` of a path inside the gem, which the browser then requests from
your site. Link your stylesheets by name, or filter it out:

```erb
<%= stylesheet_link_tag(*app_stylesheets_paths.reject { |path| path.start_with?("tailwind/") }) %>
```

To restyle the side nav, set any of its variables after that import:

```css
:root {
  --harbor-nav-bg: #1F2430;
  --harbor-nav-text: #B8C0CC;
  --harbor-nav-top: 3.5rem; /* the height of a top bar that stays put */
}
```

The full list, with what each one colours, is at the top of
`app/assets/tailwind/harbor/engine.css`.

Harbor's JavaScript is a few small Stimulus controllers (the side nav's collapse,
a log that follows its newest line, a page that refreshes itself). On `importmap-rails` with the usual
`eagerLoadControllersFrom("controllers", application)` there is nothing to do:
Harbor pins them under `controllers/harbor/`.

Harbor's pages still expect a few class names to mean something in
the host's stylesheet: `card`, `pill`, `meta`, `display`, `field`, `btn-quiet`,
`chip` (a short piece of code in a sentence), `log-pre` (a block of log or JSON),
and the colour utilities `bg-pale-green`, `text-ink-green`, `bg-pale-red`,
`text-ink-red`, `text-soft`, `text-ink`, `border-hairline`. Without them they
work and look plain.

### 7. Check it

Log in and open `/settings`. You should see the settings grouped under
Workflows, Self-improvement and Runs, each marked "Default". Change one: it
should say "Set here" and by whom. The side nav is beside the page, with
Settings marked as the current page. Log out and open `/settings` again: you
should be sent to your login page.

## Runs

Every piece of background work is a `Harbor::Run`: an agent session, a
scheduled job, a backup. It has a status, a log, a cost and what started it, so
nothing happens out of sight. Harbor's migration creates the `runs` and
`run_events` tables.

A host that wants more on its runs (who triggered one, what record it is about)
subclasses it on the same table and tells Harbor:

```ruby
class Run < Harbor::Run
  belongs_to :triggered_by_user, class_name: "User", optional: true
end
```

```ruby
# config/initializers/harbor.rb
Harbor.configure { |c| c.run_class = "Run" }
```

Harbor then builds and finds runs through that class (`Harbor.run_class`).

### Live logs

Work writes to its run's log as it goes, and the run's page reads it while it is
still running:

```ruby
log = Harbor::LiveLog.open(run.live_log_path)
log.call("fetching posts…")
Harbor::LiveLog.close(log)
```

Logs are files under `storage/harbor/logs`, one folder per kind of work. A host
that keeps them elsewhere, or names them differently, says so:

```ruby
Harbor.configure do |c|
  c.log_location = ->(path) { File.join("/mnt/logs", path) }
  c.log_path = ->(run) { "runs/#{run.id}.log" }
end
```

The log location has to be a disk the web process and the workers both see.

## Runs pages

Two pages, under `Harbor.path` like the rest: **the list** (`/factory/runs`) and **a
run's own page** (`/factory/runs/12`), with the raw stream it kept as a download
(`/factory/runs/12/raw`) and Stop (`POST /factory/runs/12/stop`). Link to them with
`harbor.runs_path` and `harbor.run_path(run)`, or `harbor_run_link(run)` from any view.

The list has the newest hundred runs, one per row: its name and status, its agent, how
long it took and when, and Stop while it can be stopped. Runs a run delegated sit under
it. On a phone a row is two lines.

A run's page has its name and status; the skill, when it started and how long it took;
its agent, model, cost, tokens and session; what it is, where it ran (runtime and
runner), its command, what started it and its timings; progress, when the work reports
any; the runs it delegated with what each cost; its parsed events (`Harbor::RunEvent`),
folded away; its live log; its error; and its input and output. While the run is under
way the page refreshes itself every five seconds (a morph, with Turbo), and the log is a
window that stays on its newest line.

### What a host adds

A host adds to these pages with partials in its own `app/views/harbor/runs/`. Harbor
renders each one where the page has a place for it, when the file exists, and nothing
when it doesn't:

| Partial | Where | Locals |
|---|---|---|
| `_show_actions.html.erb` | A run's page, in the heading beside Stop: the host's own buttons for a run | `run` |
| `_show_meta.html.erb` | A run's page, at the end of the header's first line (after when it started): who started it, say. Inline content | `run` |
| `_show_extras.html.erb` | A run's page, below the details and above the delegated runs, events and log: whole sections of the host's own | `run` |

A partial is rendered by Harbor's controller, so the host's helpers work in it, and so do
its route helpers (`retry_run_path(run)`). A button in one posts to a route of the host's.
The host can put that route at the same address as the pages:

```ruby
# config/routes.rb, above the engine's mount
scope Harbor.path do
  resources :runs, only: [] do
    member { post :retry }
  end
end
```

### What a host replaces

Two parts of the pages are partials of Harbor's that a host can replace with its own. **A
partial of the same name in the host's `app/views/harbor/runs/` is used instead of
Harbor's**, because Rails looks in an application's views before an engine's. This holds
however the engine is mounted; it does not hold for a host that prepends other view paths
ahead of its own.

| Partial | Harbor's | Locals |
|---|---|---|
| `_agent.html.erb` | The agent's name, plain. Rendered wherever a run's agent is named: each row of the list, the run page's header, the delegated runs | `run` (always one with an `agent_key`), `detail` (true in the run page's header and details, where there is room to say more; false in lists) |
| `_details.html.erb` | The card saying what the run is, its agent, where it ran, its model, command, what started it and its timings | `run` |

### What a host's run class decides

Three methods of `Harbor::Run` that a host's subclass (`c.run_class`) can override:

- `Run.for_page(filters)`: what the list holds, before the limit. `filters` is the page's
  query string as a hash with symbol keys. Harbor's is `top_level.recent.includes(:child_runs)`.
  A host overrides it to add a filter of its own (`/factory/runs?mine=1`) or to load what
  its partials show.
- `run.delegated_runs`: the child runs listed in the cost breakdown. Harbor's is every
  child run.
- `run.raw_log_file`: the file the raw download sends. Harbor's is `raw_log_path` under
  the log location, which is where agent sessions keep it.

### Stop

Harbor stops what it runs itself: a running agent session (`Harbor::AgentSession.stop!`),
and a queued run, which it finishes as `canceled`. Stop is offered for those and for
nothing else, and never for a run `run.cancelable?` rules out.

A host that runs work some other way says how to stop it:

```ruby
# config/initializers/harbor.rb
c.run_stop = ->(run, user) do
  MyWorkers.cancel(run.id)
  "Stopping run ##{run.id}."
end
```

It is called with the run and the current user, and returns the notice to show. Raising
says why the run couldn't be stopped, which is shown as an alert. With the hook set, Stop
is offered for every run that is `cancelable?`; sessions are still stopped by Harbor, and
everything else, queued runs included, goes to the hook.

## Models

Agents aren't given a model; they are given an alias. A `Harbor::ModelAlias`
("Thinking", "Quick") is an ordered list of `Harbor::ModelChoice`s, each a
provider's model with an effort and a usage cutoff. `model_alias.resolve`
returns the first choice whose `Harbor::ModelProvider` is switched on and below
that cutoff, so work moves to the next choice when a subscription runs low, and
the model behind a name changes in one place.

```ruby
anthropic = Harbor::ModelProvider.find_or_create_by!(key: "anthropic")
quick = Harbor::ModelAlias.create!(name: "Quick", model_choices_attributes: [
  { model_provider: anthropic, model: "claude-haiku-5-5", effort: "low" } ])
quick.resolve.model   # => "claude-haiku-5-5"
```

`Harbor::ModelCatalog.fetch(provider)` lists a provider's models for a picker.
It reads a public catalog ([models.dev](https://models.dev) by default; the
**Model catalog** setting changes the address), so it needs no API key and
shows new models as they are released. The copy is refreshed every 12 hours and
kept if a refresh fails.

A host with more on its aliases subclasses the record and names it:
`c.model_alias_class = "ModelAlias"`.

## Agents

A `Harbor::Agent` is a key, a name, a system prompt, any number of Markdown
documents (`Harbor::AgentDocument`), the tools it may use and a model alias.
`agent.full_system_prompt` is what a run is given: the house context and shared
documents every agent gets (`Harbor::AgentSetting`), then the agent's own prompt
and documents.

Work is handed out by task type. The host declares the kinds of work its code
dispatches, and who does each is a `Harbor::TaskAssignment` row edited in the
app:

```ruby
# config/initializers/harbor.rb
Harbor::TaskTypes.declare "pr_review"
Harbor::TaskTypes.declare "pr_rebase", fallback: "pr_review"       # no row of its own: use pr_review's agent
Harbor::TaskTypes.declare "issue_triage", default_agent: "planner"  # no row at all: this agent
```

```ruby
agent = Harbor::TaskAssignment.agent_for("pr_review")   # nil when unassigned or switched off
```

A host with more on its agents subclasses the record and names it:
`c.agent_class = "Agent"`.

## Agents pages

Under `Harbor.path` like the rest: **the list** (`/factory/agents`) with two more tabs,
**an agent's own page** (`/factory/agents/7`) and **its form** (`/factory/agents/new`,
`/factory/agents/7/edit`). Link to them with `harbor.agents_path` and
`harbor.agent_path(agent)`.

The list has every agent, enabled ones first: its avatar and name, its model alias, the
workspace it runs on with its limits, what it does and when it last changed. It is a
table from `lg` up and a card per agent below that.

- **Task routing** (`?tab=routing`): each declared task type (`Harbor::TaskTypes`) with
  the agent that does it, changed with a select. Saving one is
  `PATCH /factory/task_assignments/<task type>` with `agent_key`. Only the agents the
  type can be given to are offered, and one that isn't is refused.
- **Shared context** (`?tab=context`): the house context every agent is told, and each
  shared document (`Harbor::AgentSetting`), each with its own form. Saving one is
  `PATCH /factory/agents/context` with `body` and, for a shared document, its `key`
  (`shared/<path>.md`); any other key is refused.

An agent's page shows its key, model alias, workspace, limits and whether it is enabled,
then its system prompt, each of its documents, its tools, default tasks and configuration.

The form sets all of that: key (once; it can't be changed after), name, description,
avatar (PNG, JPEG, GIF or WebP up to 2 MB, judged by its bytes; a tick box removes it),
model alias, workspace, the two limits, enabled, the system prompt, documents as rows
that are added and removed in place (the `harbor--nested-fields` controller), and the
tools, default task types and configuration as JSON. JSON that doesn't parse, or is the
wrong shape, is refused with what was typed left in the form. **An agent saved from the
form needs a model alias**, because one without can't run; agents made in code are not
held to that.

### Avatars

`GET /factory/agents/7/avatar` serves the stored image, for the browser's own cache only
(`private`, with an ETag). It needs the host's login, and it is still served while the
Agents page is switched off, because other pages show avatars.

`harbor_agent_avatar(agent, size: :lg)` draws an agent in any view of the host's or
Harbor's: the image when it has one, else the first letter of its name in a circle.
Sizes are `:xs`, `:sm`, `:md`, `:lg` and `:xl`. The image's address carries when the
agent last changed (`harbor_agent_avatar_path(agent)`), so a browser never shows an old
one.

### What a host adds

A host adds to these pages with partials in its own `app/views/harbor/agents/`. Harbor
renders each one where the page has a place for it, when the file exists, and nothing
when it doesn't:

| Partial | Where | Locals |
|---|---|---|
| `_agent_columns_head.html.erb` | The agents table's heading row: the host's own `<th>`s. Rendered twice, once for each place | `slot` (`:first`: after the Agent column; `:last`: before Updated) |
| `_agent_columns.html.erb` | An agent's row: the `<td>`s under those headings. Rendered twice per row | `agent`, `slot` (as above) |
| `_routing_columns_head.html.erb` | The routing table's heading row, between Task and Agent: the host's own `<th>`s | none |
| `_routing_columns.html.erb` | A task type's row: the `<td>`s under those headings | `task_type` (its key), `assignment` (its `TaskAssignment`, or nil when unassigned) |
| `_show_facts.html.erb` | An agent's page, in the card of facts, after the model alias: each fact a `<div>` holding a `<dt>` and a `<dd>` | `agent` |
| `_form_extras.html.erb` | The form, in the grid of fields, after the description: each field a `<div>` (a cell of a two-column grid) | `form` (the form builder), `agent` |

A partial that fills one slot of the agents table renders nothing for the other
(`<% if slot == :first %>…<% end %>`). Below `lg` each row of both tables is a card, so a
cell carries its own label there, as Harbor's cells do:

```erb
<td class="block min-w-0 lg:table-cell lg:px-5 lg:py-3">
  <span class="block lg:hidden meta mb-1">Team</span><%= agent.team %>
</td>
```

### What a host configures

```ruby
# config/initializers/harbor.rb
Harbor.configure do |c|
  c.agent_class = "Agent"                     # the host's subclass of Harbor::Agent
  c.task_assignment_class = "TaskAssignment"  # the host's subclass of Harbor::TaskAssignment
  c.agent_params = %i[team]                   # what its _form_extras fields may save
  c.agent_edited = ->(agent, user) { agent.edited_by = user.name }
end
```

- **`agent_params`**: attributes of the host's agent class that the form may save, beyond
  Harbor's own. They are assigned before Harbor's fields, so where one of them sets
  something a field of Harbor's also sets, the field wins. Anything not named is left out.
- **`agent_edited`**: called with (agent, current user) when someone saves an agent from
  the form, new or existing, after the form's values are assigned and before the agent is
  checked and saved. What it sets on the agent is saved with the rest. It is not called
  for an agent saved any other way (an import, a console), nor when the form's JSON
  couldn't be read.
- **`task_assignment_class`**: two class methods a host's subclass can override.
  `compatible_agents(task_type)` is the agents a task type may be given to: the ones the
  routing tab offers and the only ones it accepts. Harbor's is every enabled agent.
  `refusal(task_type, agent_key)` is what the page says when asked for any other.

```ruby
class TaskAssignment < Harbor::TaskAssignment
  def self.compatible_agents(task_type) = super.where(team: Team.for(task_type))

  def self.refusal(task_type, agent_key) = "#{agent_key} isn't on the team that does #{task_type}."
end
```

Methods of `Harbor::Agent` the pages read, which a host's subclass can override:
`display_name`, `model_label` (what its model is called) and `effective_workspace_profile`
(the workspace shown, and selected in the form, for an agent that has none of its own).

## Runtimes and workspaces

A `Harbor::Runtime` is a place work can run, with a limit on how much at once.
The code that drives one is its backend, a subclass of
`Harbor::Runtimes::Backend` registered by name:

```ruby
# config/initializers/harbor.rb
Harbor::Runtimes.register "laptop", "Backends::Laptop"
```

A backend says what the runtime pages need to know about it, each with a default:
`offered?` (false keeps it off the "New runtime" page, for a backend a host has only
for the runtimes it already has), `choices(name)` (the kinds of runtime the form
offers for it: usually one), `fields_partial` (its own fields on the form; without
one the form has a host label and the config as JSON) and `settings_from(fields,
choice:)` (the runtime's config from what the form sent). An instance gives `label`
and `place`, which is how the list names the runtime's kind and where it is.

### The Runtimes pages

**The list** (`/factory/runtimes`) is a table, one runtime per row: whether it is
taking work (an icon and a word: taking work, not taking work with the reason, or
off), its name, kind and place, how many workspaces are in use against its limit, the
workspaces that list it, when its health was last checked, and Edit and Enable/Disable.
On a phone each row is a card.

**A runtime's own page** (`/factory/runtimes/7/edit`) has everything else: its name,
kind and that kind's fields, its limit, whether it takes new work, a health check, and
Remove (only for a runtime no workspace lists and no run used).

**New runtime** asks for a name, the kind and its fields, and a limit. Nobody types a
key: it is made from the name (`Harbor::Runtime` does this for any runtime created
without one), with a number added when the name is taken.

A workspace (`Harbor::WorkspaceProfile`) is an ordered list of runtimes, and an
agent picks one. `agent.placement` walks the list and returns the first runtime
that is switched on, healthy, below its limit and able to run one of the
agent's models, together with that model: runtime and model fall back as one
decision. Given `capacity: { owner:, ttl: }` it also takes a slot there, and
the result is `waiting?` when every usable runtime is full.

Slots are leases in Redis (`Harbor::Slots`), so Harbor needs a connection. It
uses Sidekiq's when Sidekiq is loaded; otherwise give it one:

```ruby
Harbor.configure do |c|
  c.redis = ->(&block) { MY_REDIS_POOL.with(&block) }   # yields something answering call("COMMAND", …)
end
```

### Orca

Harbor's own backend is `orca`: work runs in [Orca](https://github.com/stablyai/orca),
in a worktree Orca makes for each run. There are two kinds of Orca runtime, and the
runtime form offers both:

- **Orca**: the work runs on this server, in a folder of the Orca that runs beside the
  app. Its config names the repository: `{ "repo": "id:…" }` (an Orca repo selector:
  `id:…`, `name:app` or `path:/code/app`).
- **Orca (Remote)**: Orca still runs on this server, and does the work on another
  machine it reaches over SSH. Its config names that machine, who hosts it and the
  project: `{ "host": "ssh:<id>", "host_name": "droplet-1", "provider": "digitalocean",
  "project": "github:acme/app" }`. The host is one of Orca's SSH hosts (`orca host list`;
  add one in Orca's settings), and the project has to be set up on it in Orca first.
  Providers are listed in `Harbor::Runtimes::Backends::Orca::PROVIDERS`, which has
  DigitalOcean so far. The runner address (Settings) has to be one the remote machine
  can reach; the runtime's page warns when it is this machine's own. **This kind was
  built against Orca 1.4.257's commands and has not yet been run against a real remote
  host.**

Either kind also takes `"setup"` (whether the repository's own setup hooks run in a new
worktree: `"skip"`, the default, `"run"` or `"inherit"`) and `"environment"` (another
Orca server to ask instead, paired with this machine by `orca environment add`).

A run there is a command in a terminal of a fresh worktree. The command is
wrapped in a small sh script that posts its output and exit status back to
Harbor, so nothing is shared with the runner but the network:

```ruby
session = runtime.adapter.start(run: run, command: "make test")   # returns at once
runtime.adapter.stop(session)      # close the terminal
runtime.adapter.cleanup(session)   # remove the worktree
```

For that, set **Runner address** on the Settings page to where runners reach
the app, and let `POST` requests under `/harbor/runner/` through any firewall
in front of it. Those routes have no login: each request carries a token good
for one run, which can append to that run's log, report its result and (for an
agent session) fetch what its command needs, and nothing else. By default a
reported exit status finishes the run as ok or error;
`c.run_reported = ->(run, exit_status:) { … }` takes that over, and is called
once per run.

The script posts what the command printed about once a second. Each post says
where it starts (`POST …/log?offset=N`), so one that is sent twice adds nothing
twice, and Harbor answers `409` with its own count when a post would leave a
gap, which the script resumes from. No post is over 1 MB. The bytes are kept as
they arrive and only made valid text where a person reads them. When the
script is signalled (a closed terminal, a stop, ctrl-c) it stops the command
and everything the command started, sends what was printed and a result marked
`signalled`, and removes its files.

A command that prints nothing is still heard from: every half minute the
script sends an empty post, which says only that it is there. And the script
outlasts the app. While Harbor gives no answer (a deploy, a restart, a
network that drops) the command carries on undisturbed, what it prints is
kept on the runner, and it is all sent when Harbor answers again. A command
that ends in the meantime keeps its output and its result for up to 12 hours,
trying again every few seconds; the files fetched for it (its prompt, its
secrets) are removed as soon as it ends, not when the output is delivered.

The runner needs `sh`, `curl` and the usual base utilities; Harbor needs the
`orca` command where it runs. An Orca server listens on every interface, so
never give one a public address.

`c.sticky_runtime` sends follow-up work back to the runtime that holds its
workspace, and `c.runtime_class` / `c.workspace_profile_class` name a host's
subclasses.

## Agent sessions

An agent session is one run of an AI coding agent's command line, `claude -p`
for an Anthropic model or `codex exec` for an OpenAI one, as the command in an
Orca terminal. Only HTTP passes between the machine it runs on and the app.
Harbor builds the command, and turns what comes back into the run's log, its
events, its cost and tokens, its final text and its status.

```ruby
run = Harbor::AgentSession.run!(agent: agent, prompt: "Fix the failing test in test/models/book_test.rb")
```

`run!` makes the run, places it through the agent's workspace (taking a slot on
the runtime and one of the agent's), and starts the session. It returns at
once with the run `running`; the session reports as it goes. Options:

```ruby
Harbor::AgentSession.run!(
  agent: agent, prompt: "…",                # or slash_command:, below
  attributes: { skill: "writer.fix", task_type: "fix" },   # for the new run
  system_prompt_extra: "The task: …",   # added after the agent's own prompt
  allowed_tools: %w[Read Grep Glob],     # the agent's own unless given
  disallowed_tools: %w[Bash],
  permission_mode: "default",            # the agent's own unless given
  add_dirs: [ "/srv/docs" ],
  mcp_config: { "mcpServers" => { … } },
  resume_session_id: earlier_run.session_id,
  base: "main",                          # the branch the worktree starts from
  timeout: 30.minutes, idle_timeout: 5.minutes,
  keep_worktree: false
)
```

**Tools.** By default a session has every tool. `allowed_tools` (the agent's
`tools["allowed"]` unless given) is passed as claude's `--allowedTools`, which
says what is approved without asking; with permissions skipped, the default
mode, that restricts nothing. `disallowed_tools` does take the named tools
away, in any mode. A site that wants an allow list to mean "these tools and no
others" turns on **Enforce agents' allow lists** on the Settings page: a
session is then also started with `--tools`, so a built-in tool that isn't on
the list doesn't exist for it (`"Bash(git status)"` keeps Bash). An MCP
server's tools are governed by the servers the session is given, not by these
lists.

When the agent or every usable runtime is full, or no model is available,
nothing starts: `run!` gives back what it took and returns the run still
`queued` (or `waiting_for_model`) with the reason in its log. Call
`run!(agent:, prompt:, run: that_run)` to try again. `Harbor::AgentSession.start!`
is the same without placement, for a host that has already chosen a `runtime:`
and a model `choice:`.

### A slash command for a prompt

The prompt can be a file in the repository the agent works in, named the way
Claude Code names its custom commands:

```ruby
Harbor::AgentSession.run!(agent: agent, slash_command: "/tidy:shelf 12 --fast", command_ref: "origin/main")
```

Give `prompt:` or `slash_command:`, one of the two (anything else is an
`ArgumentError`). The first word is the command's name and the rest are its
arguments, split on whitespace: quotes don't group words.

- **The name is a path under `.claude/commands`.** `/tidy` is
  `.claude/commands/tidy.md`, `/tidy:shelf` is `.claude/commands/tidy/shelf.md`,
  and each further colon is one more folder. A part of a name is letters,
  digits, dots, dashes and underscores. A name with anything else in it (a
  slash, `..`, an empty part) raises an `ArgumentError` before a run is made or
  touched. The leading slash may be left off.
- **The file is read on the runner machine**, where the repository is, as the
  first step of the agent command; Harbor never sees it. That step is plain
  `sh` with `git`, `cat` and `awk`.
- **`command_ref:`** names a git ref (`origin/main`, a tag, a commit): the file
  is then read with `git show <ref>:<path>` and the checked-out copy is ignored.
  It exists for a session that works on a branch somebody else wrote, such as a
  review of a pull request: without it, the branch under review could change
  the instructions of its own reviewer. Harbor does not fetch, so the ref is
  whatever the runner's repository has by that name. With no `command_ref:`
  the file is the worktree's, committed or not.
- **What becomes the prompt.** A leading YAML frontmatter block (from a first
  line starting `---` to the next line starting `---`) is dropped, with the
  blank space after it. `$ARGUMENTS` becomes all the arguments joined by single
  spaces, then `$9` down to `$1` become the arguments by position, or nothing
  for one that wasn't given. There is no `$10`: it is `$1` followed by a `0`.
  Everything else in the file, and everything in an argument, is only text:
  nothing is run or expanded by a shell. The CLI's own slash commands aren't
  used; it gets the finished text as its prompt, like any other.
- **A file or a ref that isn't there** stops the command before the CLI starts,
  with one line such as
  `ERROR: slash command /tidy:shelf not found: no .claude/commands/tidy/shelf.md at origin/main in /work/tree`
  and exit status 66, so the run ends as an `error` with that line.

`runs.command` shows the slash command (`claude -p /tidy:shelf 12 --fast --model …`),
and it is kept with the run (`input["agent_session"]["command"]`), so a session
started again without `--resume` expands it again.

### What the agent is told

The system prompt is the agent's own (`agent.full_system_prompt`), then a
paragraph of Harbor's saying the run is unattended (never ask a question, never
wait for input, on a failed precondition print a line starting `ERROR:` and
exit non-zero), then the host's line, then `system_prompt_extra`.

### Hooks

```ruby
# config/initializers/harbor.rb
Harbor.configure do |c|
  # The environment of the agent command, per run. This is where secrets come
  # from: a model credential, a source-control token, a git author.
  c.agent_session_env = ->(run, provider) do
    env = { "GH_TOKEN" => Tokens.for(run), "GIT_AUTHOR_NAME" => "Build Bot", "GIT_AUTHOR_EMAIL" => "bot@example.com" }
    env["CLAUDE_CODE_OAUTH_TOKEN"] = ENV["CLAUDE_CODE_OAUTH_TOKEN"] if provider == "anthropic"
    env["CODEX_API_KEY"] = ENV["OPENAI_API_KEY"] if provider == "openai"
    env
  end

  # A line or two for the system prompt: who the agent acts as, the site's rules.
  c.agent_session_preamble = ->(run) { "You act as the build-bot account. Never push to main." }

  # Called once when a session has ended, however it ended, after Harbor has
  # recorded it and cleaned up.
  c.agent_session_finished = ->(run) { FollowUpJob.perform_later(run.id) }

  # The agent commands as the runner machines know them.
  c.claude_bin = "claude"
  c.codex_bin = "codex"
end
```

Harbor adds no secret of its own. It applies one rule to what the hook
returns: `claude` takes a single credential, so when the hash has
`CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` is unset for the command, and
the other way round. With neither, the machine's own login is used.

### What the runner machine needs

`sh`, `curl`, the agent command (`claude`, or `codex`) on its `PATH` (and `git`
and `awk` for a slash command), and either
a login for it on that machine or a credential passed by the host's hook. A
machine without the command says so in the run's log and the run ends as an
error (exit 127).

### Where secrets travel

The terminal's command line carries the run's address, its token and the names
of four files, and nothing else. The runner script fetches those files over
HTTPS with the token (`POST /harbor/runner/runs/:id/bundle/:name`) into a
private folder (`$HARBOR_RUN_DIR`, mode 700, removed at the end): `prompt`
(or `arguments`, a slash command's, one to a line), `system`, `mcp` and
`env`. `env` is `export NAME='value'` lines the script
sources before the command starts, so a secret is never an argument of any
process and never in the terminal's command line. Harbor works `env` out from
`agent_session_env` each time it is asked, only while the session is running,
and stores none of it. The agent command is not given the run's token.

The prompt (or the slash command), system prompt and MCP config are kept with the run
(`input["agent_session"]`), so put no secret in an MCP config: give it to the
command through `agent_session_env` and name the variable in the config.

### MCP servers

Every session gets an MCP config of its own and `--strict-mcp-config`: the
servers in `mcp_config:`, or none. A session never inherits the MCP servers of
whoever owns the machine. For `codex` the same servers are passed as config
overrides, in a `CODEX_HOME` of the session's own.

### Stopping and timeouts

```ruby
Harbor::AgentSession.stop!(run)   # status "canceled"
```

`stop!` records why, closes the terminal and finishes the run at once, without
waiting for a result. The runner script, signalled by the closing terminal,
stops the agent and everything it started (TERM, then KILL). It is safe to call
twice and on a finished run, and a result that arrives afterwards is ignored.

Three checks run as Active Job jobs (`Harbor::AgentSession::WatchJob`), so the
host needs a queue that honours `set(wait:)`:

- **`timeout:`** (30 minutes unless given): a session still running then is
  stopped with status `timeout`.
- **`idle_timeout:`** (off unless given): a session that prints nothing for
  that long is stopped with status `timeout`.
- **The silent-runner check**: when nothing has arrived for the **Silent runner
  check** setting (10 minutes), not even the runner's word that it is there,
  Harbor asks Orca whether the terminal's command is still there. If it has
  gone, no result is coming: the session was interrupted (below). A quiet
  session whose terminal is still busy is left alone.

A session that was asked to continue an earlier one (`resume_session_id:`) and
fails before the agent gets a turn, because that session is gone, is started
once more in the same worktree without `--resume`.

### Restarts and interruptions

Neither the app nor Orca going down ends a session's work.

**The app is down** (a deploy, a restart, a crash). Sessions run in Orca
terminals, not in the app's jobs, so they carry on. Their runners keep what is
printed and deliver it, and the result, when the app is back (see Running
work on another machine). When the job workers start, Harbor picks every
running session up again (`Harbor::AgentSession.recover!`): its checks are
queued again in case the queue lost them, and a session that had been
interrupted is started again. Under Sidekiq this happens by itself; a host on
another queue calls `recover!` when its workers start.

**A session is interrupted** when it was cut off by something other than its
own ending and Harbor had not stopped it:

- its terminal went away with no result (the machine restarted, Orca was shut
  down and took its terminals with it), found by the silent-runner check;
- its runner reports that it was signalled out of a command that was still
  running (a closed terminal, a machine shutting down);
- the app went down while the session was being started, so it has no
  terminal at all.

An interrupted session is not finished. It is started again in the worktree it
already has, with everything the agent had written still there:

- **claude** continues its own conversation: `claude --resume <its session>`,
  with a short prompt saying it was interrupted, that a command may have been
  cut off part-way, and to carry on. If that conversation turns out to be gone
  it starts over, as below.
- **codex**, and a session that had not yet got as far as a conversation,
  **start over** from the first prompt in the same worktree, with a paragraph
  added to the system prompt saying an earlier attempt was cut off and its
  unfinished work may be there.

Whatever is still running in the worktree is closed first, and each start is a
new attempt, so anything a cut-off runner still sends is refused and it stops
its command. While Orca can't be asked (it is still coming back up) the
session waits and is tried again every minute, for up to six hours; after
that the run is finished as an `error` saying why. The time a session spent
interrupted is not counted against its `timeout:`.

One session is started again at most **Starts after an interruption** times
(a setting, 3; 0 finishes an interrupted session as an `error`, as before
0.18). To end a session, stop it (`stop!`, or the run's page): closing its
terminal by hand now reads as an interruption.

The run's cost and tokens are those of its last attempt. An attempt that was
cut off never reports its own, so they are not known.

### How a session ends

Whichever way it ends, one finisher runs once: it writes `session_id`, `model`,
`cost_usd_actual`, `duration_ms`, the four token counts, `error_class`
(the result's subtype when it wasn't a success) and
`output = { "exit_code" => …, "text" => … }` (the agent's final text, or the
end of what it printed otherwise). A recorded stop decides the status
(`canceled`, `timeout`); otherwise exit 0 is `ok` and anything else `error`,
with the last plain lines the command printed as the error. Then it gives back
the slots, closes the terminal, removes the worktree (unless
`keep_worktree: true`) and calls `agent_session_finished`. A failure in any of
those is logged in the run's log and never leaves the run unfinished.

### Where the stream and the log live

Beside each other, under the log location (see Live logs): the live log at
`run.live_log_path` holds one readable line per event, and the raw stream at
`run.raw_log_path` (the same name ending `.ndjson`) holds exactly the bytes the
command printed. `run.run_events` has one row per event, added as they arrive.
`Harbor::AgentSession::Stream.parse(File.read(…))` reads a raw stream again,
including the subagents the agent delegated to (`stream.delegations`): Harbor
returns those as data and records nothing for them.

### Not done yet

- **Queueing.** A run that could not start is returned waiting; when to try
  again is the host's.
- **Changing model mid-run.** A session runs on the model it started with.
- **MCP servers hosted by Harbor.** `mcp_config:` names servers that exist
  elsewhere.
- **`codex`** is built from its documentation and tested against a stand-in;
  it has not been proven against a real server. It does not continue earlier
  sessions.

## Automations

An automation is one thing a site does on its own: a row a person can read,
switch off, reschedule and run by hand. `Harbor::Automation` has two kinds:

- **`agent`**: an agent, with instructions or a slash command. Made and edited on the
  Automations page, with no deploy. When it fires, Harbor runs it as an
  [agent session](#agent-sessions) of that agent.
- **`job`**: one of the site's own job classes. Made in code (a seed), because a job
  class is code; the page edits only its name, description, category, schedule and switch.

and three things that start one: a **schedule** (a cron, `trigger_kind: "schedule"`),
**by hand** (`"manual"`, the "Run now" button, which works for every automation), or a
**trigger the host declared** and fires itself (below).

Every firing is a tracked run with `automation_id` set, so the list's "Last run" is the
same record the Runs pages show. Harbor's migration creates the `automations` table.

A site with no code of its own needs one thing beyond the gem: the tick on a schedule.

### The tick

`Harbor::Automations::TickJob` starts every enabled scheduled automation whose cron came
due since it last fired. Run it every minute, with whatever scheduler the site has.
Harbor doesn't require one:

```yaml
# sidekiq-scheduler or sidekiq-cron (config/sidekiq.yml)
:scheduler:
  :schedule:
    harbor_automations_tick:
      cron: "* * * * *"
      class: Harbor::Automations::TickJob
```

```yaml
# Solid Queue (config/recurring.yml)
production:
  harbor_automations_tick:
    class: Harbor::Automations::TickJob
    schedule: every minute
```

```ruby
# anything else that can run code every minute (cron with bin/rails runner, a clock process)
Harbor::Automations::Tick.call
```

That entry is the only cron a site keeps. Every schedule is a row, changed on the page.

- **Never twice for one due time.** The tick claims a due time with a compare-and-set
  on the automation's `last_scheduled_at` in the database, so two ticks running at once
  start it once.
- **Once after an outage.** An automation that missed twenty due times while the
  workers were down fires once, for the latest.
- **A start that raises is tried again.** If the queue is down or a job won't enqueue,
  the due time is handed back and the next tick tries it. The failure is still a run.
- **A schedule counts from when it was set.** An automation made at 10:00 with
  `0 8 * * *` first fires tomorrow at 08:00, not on the next tick; the same when its
  cron changes or it is switched back on.
- **A run still going holds the next one back**, unless the automation allows
  concurrent runs. The due time is used up, not queued behind it.
- **Crons are read in the process's time zone** (`TZ`, else the app's `Time.zone`), by
  [fugit](https://github.com/floraison/fugit). The pages name the zone.

The tick is not a run itself; it logs one line per automation it starts.

### Starting one

`Harbor::Automations::Dispatch.call(automation, trigger_source: "manual")` is what the
tick, "Run now" and a host's own trigger all call. It returns a result with `run` (the
run, when there is one yet), `note` (why not, or what to tell the person) and
`skipped?`. It also takes `triggered_by_user:`, `trigger_ref:`, `context:` (a hash:
it becomes the run's input, and fills `{{placeholders}}` in an agent automation's
instructions or slash command) and `idempotency_key:` (a second firing with the same
key starts nothing).

An **agent** automation becomes a queued run (`agent_key`, `skill` set to the
automation's key, `task_type` "automation", `acting_as` set to who it runs as) with
`Harbor::Automations::AgentRunJob` behind it. The job starts the session through the
agent's workspace, with the automation's timeout. While the agent or every runtime is
full, or no model is available, the run waits and the job looks again every 30 seconds.
A slash command's file is read from the git ref in the **Where slash commands are read
from** setting (`origin/main` by default; empty reads the worktree as checked out).
So this needs what any agent session needs: an agent with a model alias and a
workspace, a runtime, and the runner address set.

A **job** automation names a job class and how it is started (`job_dispatch`):

| `job_dispatch` | What happens |
|---|---|
| `loader` | Harbor makes the run, with the automation's key in the run's `loader`, and calls `JobClass.perform_later(run.id)`. `Harbor::TrackedJob` is a base class for exactly this |
| `skill` | The same, with the key in the run's `skill` |
| `self` | The job makes its own run. Harbor calls `JobClass.automation_dispatch!(trigger_source:, triggered_by_user_id:)` and "Run now" lands on the Runs list |

The automation's `job_input` and the firing's `context` become the run's input. A job
class may refuse a firing by defining `self.automation_skip_reason(trigger_source:)`;
what it returns is shown as the reason. Job automations are made in code:

```ruby
# db/seeds.rb
Harbor::Automation.find_or_create_by!(key: "nightly-load") do |a|
  a.assign_attributes(name: "Nightly load", kind: "job", job_class: "NightlyLoadJob", job_dispatch: "loader",
                      trigger_kind: "schedule", cron: "0 2 * * *", last_scheduled_at: Time.current)
end
```

**The job class is never taken from the page.** `job_class`, `job_dispatch`, `job_input`
and `kind` are not among the fields the form saves, for a new automation or an existing
one, so a name typed into a browser is never turned into a constant. The record itself
checks only that the name resolves, so keep creating job automations to code.

### The pages

Under `Harbor.path` like the rest: **the list** (`/factory/automations`) and **the form**
(`/factory/automations/new`, `/factory/automations/7/edit`). Link to them with
`harbor.automations_path` and `harbor.edit_automation_path(automation)`.

The list has every automation, under the categories the host declared (one list when it
declared none): its name and agent, its description, what it runs, what starts it and
when it next will, its last run with its status, a switch, and "Run now"
(`POST /factory/automations/7/run`). The switch is `PATCH /factory/automations/7/toggle`.
It is a table from `lg` up and a card per automation below that.

The form for an agent automation sets its name, key (once; it names the runs' log
folder), description, agent, timeout, instructions or slash command, what starts it and
its cron, whether it is enabled and whether a new run may start while one is going.
A job automation's form has only what the page may change. An automation made on the
page can be deleted from its own page (`DELETE /factory/automations/7`); its runs are
kept. A job automation can't be deleted there.

### What a host declares

All optional, in an initializer:

```ruby
# config/initializers/harbor.rb
Harbor::Automations.category "data", label: "Data"
Harbor::Automations.category "upkeep", label: "Upkeep"
Harbor::Automations.working_folder "app", label: "The app's checkout", path: -> { Rails.root.to_s }
Harbor::Automations.identity "release-bot", label: "@release-bot"
Harbor::Automations.label :run_as, "GitHub identity"
Harbor::Automations.trigger "github", label: "On a GitHub event", kinds: %w[agent]
```

- **`category`**: a heading on the list, in the order declared, and a select on the
  form. Once any is declared every automation must have one of them.
- **`identity`**: who an agent automation may run as (`run_as`). The form gets a select,
  an agent automation must name one, and the run's `acting_as` carries it, which is what
  `config.agent_session_env` reads to give the session that identity's credentials.
- **`working_folder`**: a folder an agent automation may be told to work in (`cwd_key`;
  `automation.cwd` is its path). Harbor's own sessions work in a worktree on their
  runtime and don't read it: it is for a host that runs agent automations its own way.
- **`label`**: what the form calls the `:run_as` or `:cwd_key` field.
- **`trigger`**: a trigger kind of the host's. The form offers it, between "On a
  schedule" and "Only by hand", for the kinds named, and the record accepts it. Harbor
  never fires it: the host matches whatever it listens for and calls
  `Harbor::Automations::Dispatch.call(automation, trigger_source: "webhook", trigger_ref: …, context: …)`.
  Its fields on the form are the host's `_trigger_fields` partial.

```ruby
Harbor.configure do |c|
  c.automation_class = "Automation"       # the host's subclass of Harbor::Automation
  c.automation_params = %i[team]          # what its fields on the form may save
  c.automation_edited = ->(automation, user, values) { automation.filters = Filters.parse(values[:filters]) }
  c.automation_agent_run = ->(automation, **trigger) { MyAgentJob.start!(automation, **trigger) }
end
```

- **`automation_class`**: a subclass on the same table with what is the host's. Three
  class methods it can override: `offered_agents` (the agents the form offers; every
  enabled one), `page_defaults` (what a new automation starts with on the form) and
  `identity_refusal` (what the form says about an identity that wasn't declared). It can
  override `trigger_summary` to say its own trigger in words, and add validations.
- **`automation_params`**: attributes of the host's class the form may save for an
  agent automation, beyond Harbor's own. Anything not named is left out.
- **`automation_edited`**: called with (automation, current user, the form's values)
  when someone saves an automation from the form, after the values are assigned and
  before it is checked and saved. The values are the request's `params[:automation]`,
  unfiltered: this is where a host reads fields that aren't plain attributes. Never
  called for an automation saved any other way.
- **`automation_agent_run`**: for a host that runs agent automations its own way. Called
  with the automation and `trigger_source:`, `triggered_by_user:`, `trigger_ref:`,
  `webhook_event:`, `context:` and `idempotency_key:`; it makes the queued run, starts
  the work and returns the run, or nil when this firing already has one.
  `Harbor::Automations::Session.start!(run:, automation:, agent:, prompt:, slash_command:)`
  is there for a host that wants its own job around Harbor's session.

### What a host adds

Partials in the host's `app/views/harbor/automations/`, rendered when the file exists:

| Partial | Where | Locals |
|---|---|---|
| `_name_extras.html.erb` | The list, beside an automation's name and agent: a pill or a mark | `automation` |
| `_agent_fields.html.erb` | The form of an agent automation, at the end of "What runs" | `form` (the form builder), `automation` |
| `_trigger_fields.html.erb` | The form, at the end of "What starts it", after the cron: the fields of the host's trigger. Rendered for job automations too, so it decides for itself what to show | `form`, `automation` |
| `_hint.html.erb` | The words under the Agent, Instructions and slash command fields. What it renders replaces Harbor's; where it renders nothing, Harbor's stand | `field` (`:agent`, `:prompt` or `:slash_command`), `automation` |

```erb
<%# app/views/harbor/automations/_hint.html.erb %>
<% if field == :agent %>Only agents on the night shift. <%= link_to "Manage agents", agents_path, class: "underline" %>.<% end %>
```

## Webhooks

`Harbor::WebhookEvent` is the record of every inbound delivery, and the
Webhooks page lists them with what each one started. Receiving deliveries is
the host's: an endpoint of its own with no login, which verifies the sender,
writes a `Harbor::WebhookEvent` and starts whatever it starts.

A host with more to show per delivery subclasses the record
(`c.webhook_event_class = "WebhookEvent"`, overriding `for_page` to load what
it needs) and adds `app/views/harbor/webhooks/_event_extras.html.erb`, which
the page renders for each delivery with `event`.

## Databases

Harbor backs up the databases a site declares and restores them to the
environments it declares, on the Databases page (`/databases`). Every backup
and restore is a run.

- **Backups** come in three kinds per database. `full` is everything, for
  disaster recovery. `cleaned` is masked while it is read, so it is safe to hand
  to developers. `staging` is masked with a second set of rules, for a staging
  site that needs more kept than a laptop does. Each dump is a folder
  `<database>/<kind>/<dump id>/`, cataloged in `Harbor::DatabaseBackup` with its
  size and checksum.
- **Restore environments** are named sets of databases that get replaced with
  saved backups: a staging site, two test servers, a recovery drill. Each lists
  which database's backup, of which kind, replaces the database in which ENV
  key.
- MySQL databases get full backups only, and are never restored.

### What it needs

Nothing, until a database is declared: with none, the page says so and no tool
is run. Harbor never loads or looks for these when the app boots. They are
needed where the jobs run, when a backup or restore runs:

- [Greenmask](https://greenmask.io), which makes every PostgreSQL dump.
- `pg_dump`, `pg_restore` and `psql`, at least as new as the newest server.
- `mysqldump`, `mysql` and `gzip`, if a MySQL database is declared.
- The `aws-sdk-s3` gem in the host's Gemfile, if dumps are copied to a bucket.

### The config file

Databases and restore environments are declared in one file in the host,
`config/harbor.yml`. It is run through ERB and then read as YAML, like
`config/database.yml`. Connection strings are secrets, so they stay in ENV: the
file names ENV keys and never holds a URL.

```yaml
# config/harbor.yml
databases:
  ledger:
    source_env: LEDGER_DB_URL              # the ENV key holding its URL; point it at a read-only role
    variants_env: LEDGER_BACKUP_VARIANTS   # optional: an ENV key listing the kinds to make ("full,cleaned")
    label: Ledger                          # optional: its name on the page
    freshness:                             # optional: tables whose newest row proves the source is live
      entries: created_at
  shop:
    source_env: SHOP_DB_URL
    variants: [full, cleaned]              # optional: the kinds to make, written here instead of in ENV
  app:
    own: true                              # the app's own database
    owner: Storefront

restore_environments:
  staging:
    name: Staging
    enabled_env: STAGING_RESTORES_ENABLED  # on only when that ENV key is exactly "true"
    restores:
      - database: ledger
        backup: cleaned                    # the kind restored: cleaned, staging or full
        target_env: LEDGER_STAGING_DB_URL  # the ENV key holding the URL of the database replaced
```

A `postgres://` source is dumped with Greenmask, a `mysql://` one with
`mysqldump`. `own: true` is the database Rails is connected to: full backups
only, never restored anywhere. A database with `freshness:` tables is not backed
up once its newest row is older than the **Newest write allowed** setting,
because a source that stopped receiving writes is usually the wrong server.

An environment has a key, a name, a switch and a list of restores. One
environment may take several databases, and one database may feed several
environments. The switch is in the file and nowhere else: `enabled: true` (or
`false`), or `enabled_env:` naming an ENV key that must hold exactly `true`.
With neither, the environment is off. `backup:` says which kind a restore
uses; left out, it is the `staging` kind when the database has staging rules,
otherwise `cleaned`.

Three test servers that each take the cleaned backup of one database, and one
site that takes a full backup of another:

```yaml
databases:
  ledger: { source_env: LEDGER_DB_URL }
  shop:   { source_env: SHOP_DB_URL }

restore_environments:
  test-1:
    enabled: true
    restores:
      - { database: ledger, backup: cleaned, target_env: TEST1_LEDGER_DB_URL }
  test-2:
    enabled: true
    restores:
      - { database: ledger, backup: cleaned, target_env: TEST2_LEDGER_DB_URL }
  test-3:
    enabled_env: TEST3_RESTORES_ENABLED
    restores:
      - { database: ledger, backup: cleaned, target_env: TEST3_LEDGER_DB_URL }
  recovery:
    name: Recovery drill
    enabled_env: RECOVERY_RESTORES_ENABLED
    restores:
      - { database: shop, backup: full, target_env: SHOP_RECOVERY_DB_URL }
```

The file is read each time it is needed, so what its ERB reads from ENV is
current. A missing file declares nothing, and nothing fails. Anything else
wrong with it is never skipped over: invalid YAML, a section or key Harbor
doesn't know, a URL where an ENV key belongs, a restore of an unknown database
or of the app's own, an unknown backup kind, a missing `database:` or
`target_env:`, a database or target listed twice. Each is a
`Harbor::Databases::Error` naming the file and the entry. It is logged when the
app boots, shown on the Databases page, and raised by every operation that
reads the declarations. A mistake under `restore_environments` stops restores;
valid databases are still backed up.

Another path: `c.config_file = "/etc/myapp/harbor.yml"`. The file's top level
is where other Harbor configuration will go.

Databases may also be declared in Ruby, by a host that prefers code:
`Harbor::Databases.declare "ledger", source_env: "LEDGER_DB_URL"`, or
`Harbor::Databases.declare_each_time { |list| list.declare … }` for a list
worked out each time it is read. A database declared in the file and in Ruby
is an error. Restore environments are declared in the file only.

### Masking rules

Rules are files in the host, one per database, each a Greenmask `dump:`
section:

```
config/greenmask/<database>.yml           cleaned backups
config/greenmask/staging/<database>.yml   staging backups
```

A database gets a kind when its rules file exists. Another folder:
`c.masking_rules_path = "/srv/masking"`. The rules decide what leaves
production, so test them against sample data in the host.

### Where backups go

Where dumps go and what is run are decided on the machine, in the initializer,
not on the Settings page. Each value may be a callable, read when needed:

```ruby
Harbor.configure do |c|
  c.backup_root = "/mnt/backups/databases"   # default: storage/harbor/backups in the app
  c.backup_host_root = "/Volumes/backups"    # optional: that folder as shown on the page, when the app sees it through a mount
  c.greenmask_bin = "greenmask"              # the default
  c.greenmask_pg_bin_path = "/usr/lib/postgresql/16/bin"   # default: wherever pg_dump is on the PATH
  c.backup_bucket_env_prefix = "MYAPP_BACKUP_S3"            # default: HARBOR_BACKUP_S3
end
```

The local folder always gets every dump, and restores read from it. It has to
be a disk the workers see, with at least **Free space needed** free.

To copy dumps to an S3-compatible bucket as well (Amazon S3, Cloudflare R2,
DigitalOcean Spaces, Google Cloud Storage), set these in ENV, under the prefix
above:

| ENV key | |
|---|---|
| `…_ENDPOINT` | The provider's S3 endpoint. R2: `https://<account id>.r2.cloudflarestorage.com` |
| `…_ACCESS_KEY_ID`, `…_SECRET_ACCESS_KEY` | A key that can write to the buckets |
| `…_REGION` | Optional. `auto` when unset, which is what R2 expects |
| `…_CLEANED_BUCKET` | Where cleaned dumps go. Give developers a read-only key to this one only |
| `…_FULL_BUCKET` | Optional. Where full and staging dumps go: private, for disaster recovery |
| `…_LOCATION` | Optional. The provider's short name on the page (`r2`, `spaces`, `gcs`, `s3`); guessed from the endpoint |

A kind with no bucket stays in the local folder only. Buckets keep the
folder's layout, so `greenmask restore latest` works against either.

### Settings

Under **Databases** on the Settings page: **Backups kept**, **Parallel dump jobs**, **Free space needed**,
**Newest write allowed**, **Oldest backup a refresh uses**, **Connection
timeout** and **Upload threads**.

### What a restore will and will not replace

A restore drops every schema in its target first. A database can be a target
for one reason only: **the config file lists it as the `target_env` of a
restore, in an environment that file has switched on.** Nothing else makes a
database replaceable, and nothing about what it is called matters: Harbor never
looks at a database's or a host's name to decide whether it is safe.

So nothing in a browser can cause a restore the file doesn't describe. There is
no setting, form field or request parameter that switches an environment on,
adds a target, changes a target or changes the kind of backup restored. The
page sends only which environment, database and backup; the rest is read from
the file.

On top of that, every restore is checked before it is queued and again by the
job, and an environment restore checks every one of its entries before it
replaces the first database. None of these can be overridden:

- The target is never a declared database's source, the app's own
  `DATABASE_URL`, or any database in Rails's own configuration. Two URLs are
  the same database when host, port and database name match: hosts without
  case and without a trailing dot, the port defaulted when a URL names none,
  names without case and after percent-decoding. The user, password and
  parameters don't matter. (Two different names for one server, such as an IP
  address and a DNS name, are not known to be the same; give each database one
  name.)
- No target is shared by two restores, anywhere in the file.
- A target whose ENV key is unset or blank is refused. An environment restore
  leaves such an entry out and says so in its log; it is never pointed at
  anything else.
- A restore uses exactly the kind of backup its entry names. A `full` dump
  holds everyone's real data, and is restored only where the entry says
  `backup: full`.
- The dump's size and checksum must match what was cataloged.
- The target is PostgreSQL, and so is the dump.
- An environment restore refuses a backup older than the **Oldest backup a
  refresh uses** setting.

While a restore runs, the role in the target's URL is made read-only and its
other connections are closed (`c.staging_lock_role` names another role;
`c.restore_spared_applications` lists application names whose connections are
left alone).

### The Environments tab

The Databases page's **Environments** tab lists each environment: whether it is
on and what decides that (the ENV key's name or the file's line, never a
value), each restore with its backup kind, its target without the password,
whether its ENV key is set and why it would be refused if it would be, the
last restore, and a button to restore it when it is on.

### Starting operations

The jobs are tracked runs. `Harbor::DatabaseRestoreJob` restores one chosen
backup into one environment, and `Harbor::EnvironmentRestoreJob` restores every
database of an environment from its newest backups. Backing up is a job the
host writes on `Harbor::DbOperationJob`, because when it runs is the host's
schedule:

```ruby
class DatabaseBackupJob < Harbor::DbOperationJob
  self.loader_slug = "db-backup"

  def operate(directory:, logger:)
    Harbor::DbOps::Backup.new(run: @operation_run, logger:, directory:).call
  end
end
```

The page's buttons call the host, which creates the run and queues the job;
without this the page shows the databases and their backups and starts nothing.
The operation is `db-backup`, `database-restore` (its input names the
environment, the database and the backup), or an environment's own:
`<environment key>-restore`, with the environment's key in its input.

```ruby
Harbor.configure do |c|
  jobs = { "db-backup" => "DatabaseBackupJob", "database-restore" => "Harbor::DatabaseRestoreJob" }
  c.database_operation = lambda do |operation, user:, input:|
    run = Harbor.run_class.create!(loader: operation, trigger_source: "manual", input: input.merge(loader: operation))
    jobs.fetch(operation, "Harbor::EnvironmentRestoreJob").constantize.perform_later(run.id)   # "staging-restore", "test-1-restore", …
    run
  end
  c.database_schedule = ->(operation) { MySchedule.next_run_at(operation) }   # optional: "Next: …" on the page
end
```

A scheduled restore of an environment is the same job with the same input:
a run whose loader is `<key>-restore` and whose input is
`{ "environment" => "<key>" }`.

A host with a base job of its own for tracked work names it
(`c.tracked_job = "MyTrackedJob"`); the default is `Harbor::TrackedJob`.

## Where the pages live

Mount the engine at `/`. Harbor puts every page of its own under one path,
`/factory` by default: `/factory/runtimes`, `/factory/databases`,
`/factory/settings`. To change it, say so in `config/harbor.yml`:

```yaml
path: /ops      # or / to put the pages at the root
```

It is read when routes are drawn, so a change takes a restart. A host with
pages of the same section in its own routes puts them under the same path:

```ruby
scope Harbor.path do
  resources :reports
end
```

The runner's endpoints stay at `/harbor/runner/` whatever the path is, because
runners and firewall rules are given that address.

## Switching pages off

Every page in Harbor's menu, except Settings, has a switch under **Pages** on
the Settings page. A site that doesn't use a page turns it off: it leaves the
menu and its URLs answer as not found. Nothing running in the background is
stopped by it.

A page of the host's gets the same switch by giving it a key when adding it,
and gating its controller:

```ruby
# config/initializers/harbor.rb
c.nav.add "Reports", :reports_path, after: "Automations", key: :reports
```

```ruby
class ReportsController < ApplicationController
  include Harbor::PageGate
  harbor_page :reports
end
```

## Configuring

Harbor is configured in four places, and a value goes in the first one it can:

1. **Settings in the app.** Everything that is data: switches, limits, and
   later repositories, identities and task types. Edited on the Settings page;
   a change takes effect at once, with no deploy or restart.
2. **The environment.** Secrets only.
3. **`config/harbor.yml`.** What must be decided on the machine and never from
   a browser, because getting it wrong destroys data: which databases are
   backed up and what may be restored over what (see Databases). It names the
   ENV keys that hold the secrets.
4. **Ruby**, in a host initializer. Only what is code:

```ruby
# config/initializers/harbor.rb
Harbor.configure do |c|
  # The controller Harbor's pages inherit from (step 4).
  c.parent_controller = "ApplicationController"

  # How to name the person who changed a setting.
  c.user_label = ->(user) { user.name }

  # Called with (relative path, text) when saved configuration changes, to
  # keep a copy outside the database. Optional.
  c.export = ->(path, body) do
    file = Rails.root.join("storage", path)
    file.dirname.mkpath
    file.write(body)
  end

  # The host's own pages in Harbor's menu.
  c.nav.add "Reports", :reports_path, after: "Automations"

  # ENV keys a setting used to be read from. The ENV value applies until a
  # value is saved on the Settings page.
  c.env_fallback :workflows_enabled, "MYAPP_WORKFLOWS_ENABLED"
end
```

The hooks for agent sessions (`agent_session_env`, `agent_session_preamble`,
`agent_session_finished`, `claude_bin`, `codex_bin`) are under Agent sessions.
What the Agents pages take (`agent_params`, `agent_edited`, `task_assignment_class`) is
under Agents pages.
What automations take (`automation_class`, `automation_params`, `automation_edited`,
`automation_agent_run`, and what a host declares with `Harbor::Automations`) is under
Automations.

### Settings

A setting is declared in `lib/harbor/settings/declarations.rb` with a key,
type, default and description, and read with:

```ruby
Harbor::Setting.get(:agent_auto_retries)
```

A saved value wins, then the host's ENV fallback, then the default. The page
shows which of the three each value comes from. An undeclared key can't be
read or saved.

## Rules for code in this repository

- **Harbor does not know its host.** No host's models, repositories, logins,
  paths or URLs, in code, seeds or copy. What Harbor needs from a host arrives
  as a setting or through `Harbor.configure`.
- **A new switch or limit is a declared setting**, not an ENV key.
- **Secrets are never stored in settings.**

## Developing

The tests run against a small host app in `test/dummy`, on Postgres:

```bash
bundle install
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432 bin/test
bundle exec rubocop
```

`DATABASE_URL` names the server and credentials; the database is always
`harbor_dummy_test`.

## Releasing

1. Update `lib/harbor/version.rb` and add the version to `CHANGELOG.md`.
2. Merge to `main`.
3. Tag that commit `vX.Y.Z` and push the tag. Hosts pin a tag, so nothing changes for
   them until they move to it.

## Licence

MIT. See `LICENSE`.
