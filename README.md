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
gem "harbor-engine", github: "hardcoverapp/harbor-engine", tag: "v0.27.0"
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

Harbor's pages then live under `/factory` (`/factory/settings`); "Where the pages
live" says how to change that.

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

The side nav lists every page of Harbor's that is switched on and the host's
own, in groups (Overview and Velocity first, then Flows, Activity, Agents,
Infrastructure, Quality), each with an icon. It collapses to
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
the side nav, the tabs and Harbor's default look, and makes Tailwind read
Harbor's views.

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
a log that follows its newest line, a page that refreshes itself, a picker that
submits its form when changed) and the workflow builder. On `importmap-rails` with the usual
`eagerLoadControllersFrom("controllers", application)` there is nothing to do:
Harbor pins them under `controllers/harbor/`.

**The default look.** Harbor's pages are drawn with a small set of colours and
component classes, and Harbor's styles define all of them
(`app/assets/tailwind/harbor/theme.css`), so a site with no stylesheet of its own
gets finished pages: warm greys, with washed pastels kept for status. A site with
its own look changes any part:

- **A colour**, by setting the same token after the import. The tokens are
  `canvas`, `bone`, `surface`, `ink`, `body`, `soft`, `faint`, `hairline`, and a
  `pale-` and `ink-` pair for each of `red`, `blue`, `green`, `yellow`, `orange`,
  `purple` and `teal`:

  ```css
  @theme { --color-ink: #0B1F3A; --color-hairline: #D9DEE5; }
  ```

- **A component**, by defining the class itself: `card`, `pill`, `meta`, `display`
  (a page's heading), `field`, `btn-primary`, `btn-quiet`, `chip` (a short piece of
  code in a sentence) and `log-pre` (a block of log or JSON). Harbor's are in the
  base layer, so a host's rule for the same name wins, layered or not, and so does
  a utility class beside it. A bar chart's hover bubble (`spark`, `spark-col`,
  `spark-tip`) works the same way.

- **The room around a page**, with utilities on the shell's `harbor-page` element
  (`class="harbor-page px-10 pb-24"`); without any, Harbor gives it a margin.

Harbor sets no font and nothing on `body`: those are the host's.

### 7. Check it

Log in and open `/factory`. You should see the Overview page beside the side
nav. Then open `/factory/settings`: the settings are in groups, each marked
"Default". Change one: it
should say "Set here" and by whom. The side nav is beside the page, with
Settings marked as the current page. Log out and open `/factory/settings` again: you
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
any; what the scorers made of it, with "Score now" (see Scorers); the runs it delegated
with what each cost; its parsed events (`Harbor::RunEvent`),
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
  child run but a scorer's judge, which has a bill of its own.
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
choice:)` (the runtime's config from what the form sent), `unoffered_note` (a line
the "New runtime" page shows while the backend isn't offered: what to declare first)
and `page_partial` (something of its own on a runtime's page, below the form). An
instance gives `label` and `place`, which is how the list names the runtime's kind and
where it is.

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

Harbor has three backends of its own, `orca`, `conductor_cloud` and `orca_per_workspace`
(both below), and the runtime form offers four kinds of runtime between them: Orca,
Orca (Remote), Conductor Cloud and, for a site that has declared a recipe, Orca (per
workspace), which starts a machine for each run.

With `orca`, work runs in [Orca](https://github.com/stablyai/orca),
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

**Where the Orca server is.** With nothing else said, Harbor runs the `orca` command
against the Orca on its own machine. For an Orca server elsewhere there are two ways:
`"environment"` names a server this machine has saved with `orca environment add`, and
`"pairing_code_env"` names the environment variable that holds a server's pairing code
(`orca serve` prints one), which Harbor sends with every command. The second keeps
nothing on disk, so it is the one for an app in a container: put the `orca` command in
the image and the code in the container's environment (it is a secret; the runtime only
names the variable). The second way has been run against a real headless Orca server (1.4.257). A server
that has just been started knows no repository: name it by its folder there
(`"repo": "path:/srv/app"`) and Harbor adds it the first time. Orca won't list a
server's SSH hosts through a pairing code, so for Orca (Remote) on such a server the
host is typed.

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

### Conductor Cloud

The backend `conductor_cloud` runs work in [Conductor Cloud](https://www.conductor.build):
each run gets a cloud workspace Conductor makes from a repository, and the agent runs
there. The runtime form offers it as one kind, **Conductor Cloud**. Harbor needs no
`orca` command for it and no runner address: it talks to Conductor's REST API
(`Harbor::ConductorCloud::Client`), and nothing in the workspace talks back.

**The session side has not been run against the real service.** The client makes the
calls a host already uses against Conductor's API; the way Harbor follows a
session with them (below) was built from that host's experience and Conductor's
documentation, and is tested against a stand-in for the API. Expect to find something
the first time a real session runs.

**What the runtime needs.** A Conductor account with an API key, and a repository that
account can read. The fields on the form, which are the runtime's config:

- **Repository** (`"repository_url"`): the repository's address
  (`https://github.com/acme/app`). Conductor clones it into a new workspace for each run.
- **Branch** (`"branch"`): the branch a workspace starts from. Empty: the repository's
  default. A session's own `base:` wins.
- Under Advanced, **API key variable** (`"api_key_env"`): the name of the environment
  variable that holds the Conductor API key, `CONDUCTOR_API_KEY` unless another is
  named. The key is a secret: it is read from the environment each time it is used, is
  never typed into the form, never stored and never shown. The form says only whether
  the variable is set. A runtime whose variable is empty takes no work and says which
  variable.
- Under Advanced, **API address** (`"api_url"`): where Conductor's API is, for one
  that isn't the public `https://api.conductor.build`.

The list shows such a runtime as "Conductor Cloud · acme/app". Its health check is one
read-only call to the API.

**Models.** Conductor takes its own model ids (`opus-5-5-1m`), not the ids a model alias
holds (`claude-opus-5-5`). `Harbor::ConductorCloud::Models` has the ids Conductor is
known to take and finds one for a model: an id of Conductor's own is itself;
`claude-opus-5-5`, `claude-opus-5.5` or a dated id is the same family and version, with
its 1M-context variant when Conductor has one; a bare family (`opus`) is the first id
of that family in the list. A model with no id there is one this backend can't run, so
placement passes over it (`supports?`), and on to the alias's next choice or the
workspace's next runtime.

**How a session runs there.** `Harbor::AgentSession` is used the same way, and
`Harbor::Automations::AgentRunJob` and a workflow's agent step need nothing different:
the runtime the run is placed on decides. What is different from an Orca session:

- **No terminal and no runner script.** Starting the session is one API call that
  makes the workspace (named `harbor-run-<run id>`) and its first session, which starts
  on the first message. `runs.command` reads
  `claude <prompt…> --model sonnet-5-5-1m --effort medium (Conductor Cloud)`.
- **The first message is everything the agent is told.** Conductor has no separate
  system prompt, so the agent's own instructions, Harbor's unattended-run paragraph,
  the host's line and `system_prompt_extra` go first, then a rule, then the prompt.
- **A slash command is an instruction, not an expansion.** The runner step that expands
  a command's file doesn't exist here, and sending `/name args` as the whole message
  (which Claude Code would expand itself) would leave the agent without its
  instructions. So the task is "read `.claude/commands/<name>.md` (at `command_ref`
  when one was given, with `git show`) and carry out its instructions", with the
  arguments listed. The agent does the substitution, not `awk`.
- **The environment is sent to Conductor.** What `config.agent_session_env` returns for
  the run becomes the workspace's environment, in the API call that makes it. Harbor
  still stores and logs none of it, but it does leave the app: Conductor holds it for
  the workspace. Conductor's own `gh` wrapper acts as the account that owns the
  workspace whatever `GH_TOKEN` says; a host whose agents must act as someone else
  tells them to call `"${CONDUCTOR_REAL_GH_PATH:-gh}"` (in `agent_session_preamble`).
- **Tool rules, MCP servers and added folders are not applied.** Conductor starts the
  agent with its own settings. The run's log says which of them were set and passed
  over, the backend answers `enforces_tool_policy?` with false, and work that requires
  its tool rules is never placed here.
- **An earlier session can't be continued.** `resume_session_id:` is dropped, with a
  line in the log: the conversation it names lived in a workspace that is gone.
- **Harbor asks; nothing reports.** A job (`Harbor::AgentSession::PollJob`) looks at
  the session every **Conductor Cloud: seconds between checks** (a setting, 10). While
  the workspace is setting up it asks only for the workspace's status. Once it is
  ready it reads the transcript messages after the last one it read and asks for the
  session's status. Each message's `rawPayload` is the agent's own event, so the
  messages go, one to a line, through the same recorder an Orca session's output does:
  the live log, the run's events, the raw stream, and at the end the cost, tokens,
  session id and final text are the same.
- **Setup is not the run's time.** A new workspace runs the repository's setup first.
  That may take up to **Conductor Cloud: workspace setup** (a setting, 30 minutes)
  before the run is finished as an error; the run's `timeout:` and `idle_timeout:`
  count from the moment the workspace is ready. The run's capacity slots are leases
  sized for the timeout as first given, so after a long setup they can lapse before
  the session ends, as after an interruption.
- **How it ends.** The run is finished when the transcript holds the agent's result (a
  successful one is `ok`; any other is an `error` with what the agent said), when the
  session goes idle after working with no result (`error`), when Conductor reports the
  session as errored, when the workspace fails its setup or is archived, or when the
  session has sat idle for 15 minutes without ever working (its message was never
  delivered).
- **Stop and timeouts** cancel the session through the API, and the finisher archives
  the workspace (unless `keep_worktree: true`).
- **Conductor's API being away is not a failure.** A 5xx, a timeout or a refused
  connection says nothing about the session, which keeps working in the cloud: that
  look is skipped, the log says so once and says when the API answers again, and the
  next look reads on from the same place. The run's timeout still bounds the wait.
  Anything else Conductor refuses (an unknown session, a key it won't take) ends the
  run as an `error`. The call that makes the workspace is never retried on an outage:
  that could start the work twice.
- **Restarts.** The session runs in Conductor, not in the app, and what Harbor needs to
  follow it is on the run (`runner_state["conductor"]`: the phase, when it began, the
  last message read; `runner_state["session"]`: the workspace and session ids). When
  the job workers start again `Harbor::AgentSession.recover!` begins following every
  such session again, and a look left over from before stops. Nothing is started again:
  there is no terminal to lose, so the silent-runner check only begins the following
  again. The one interruption that exists is the app going down while the session was
  being started: a workspace made for the run and never recorded is archived (found by
  its name), and the run starts over in a new one.

**What a host can change.**

```ruby
Harbor.configure do |c|
  # The User-Agent of Harbor's requests to Conductor. By default it names
  # Harbor and its version, and not the site.
  c.conductor_cloud_user_agent = "acme-factory (factory.example.com)"
  # Model ids Conductor takes that Harbor doesn't list yet, newest first.
  c.conductor_cloud_models = %w[opus-6-1m]
end
```

A subclass of `Harbor::Runtimes::Backends::ConductorCloud`, registered in its place
(`Harbor::Runtimes.register "conductor_cloud", "Backends::MyConductor"`), can override
`model_id_for(model)` (its own naming of models), `default_repository_url` (what the
form's Repository field starts from), `form_note` (a line above the fields),
`workspace_name(run, attempt)`, `first_message(run)`, and `agent_sessions?`: a host
that drives Conductor its own way on these runtimes and wants none of Harbor's sessions
placed there answers false, and a session sent to one fails with "can't run agent
sessions", as on any backend that can't start one.

### A machine for each run

The backend `orca_per_workspace` gives each run a machine of its own: Harbor starts one
when the run is placed, runs the work in the Orca on it, and removes it when the run
ends. The runtime form offers it as **Orca (per workspace)**, once the site has declared
a recipe. It is for a site with no machine of its own to run agents on: the app can be
a container, and each run's machine comes and goes.

**It has been run end to end against a real Orca server, not yet against a machine at a
provider.** With the example recipe (`examples/environment-recipes/`, whose "machine" is
a second headless Orca server on the same computer, Orca 1.4.257), Harbor ran `create`,
reached the new server with its pairing code, added the repository, made a worktree, ran
a command in a terminal there, and ran `destroy`, which stopped the server; the pairing
code was in no log or column and was gone afterwards. What has not happened yet is a
recipe that starts a machine at a provider, with the runner posting back from it and an
agent running there. Expect to find something the first time. The recipe contract was
read from Orca's guide (`orca skills get orca-per-workspace-env --full`) and from what
that version does when it runs a recipe.

**Why Harbor runs the scripts.** Orca has per-workspace environment recipes of its own:
a repository's `orca.yaml` lists recipes whose `create` script starts a machine and
whose `destroy` script removes it. But a recipe is only chosen in Orca's desktop app:
`orca worktree create` has no way to name one, so Harbor can't ask Orca to do this. It
runs the recipe's scripts itself, to exactly Orca's contract, so the same scripts work
from Orca's picker and nothing in them is Harbor's.

#### Declaring a recipe

Recipes are declared in `config/harbor.yml`, the same file as Databases (ERB, then
YAML). A recipe's commands are only ever read from that file: the runtime form chooses
a recipe by name and nothing typed into a page is ever run.

```yaml
# config/harbor.yml
environment_recipes:
  aws-sandbox:
    name: AWS sandbox
    create: ./scripts/orca-vm/aws-create.sh
    destroy: ./scripts/orca-vm/aws-destroy.sh
    timeout_seconds: { create: 1800, destroy: 120 }
```

| Key | Meaning |
| --- | --- |
| `name` | What the pages call it. The id when left out. |
| `create` | The command that starts a machine and prints its result. Required. |
| `destroy` | The command that removes the machine, or `none` when there is nothing to remove. Required. |
| `suspend`, `resume` | Read and checked (both or neither), **not run yet**. |
| `timeout_seconds` | One number for every step, or a map of `create`, `suspend`, `resume`, `destroy`. Whole seconds, 1 to 86400. |

The keys and their meanings are `orca.yaml`'s `environmentRecipes`, so a recipe can be
copied between the two. Where Harbor's differs:

- **A mapping keyed by id**, where `orca.yaml` has a list with `id:`. The config file
  refuses a key that appears twice, so two recipes can't share an id.
- **`timeout_seconds`**, as the rest of the file is written. `timeoutSeconds` is read too,
  and so are Orca's legacy `command` and `cleanup` for `create` and `destroy`.
- **A mistake is an error.** Orca reports a bad timeout and runs the step with none.
  Harbor refuses the file, says what is wrong (`config/harbor.yml:
  environment_recipes.aws-sandbox: needs destroy: …`) on the runtime form and the
  runtime's row, and places nothing there until it is fixed. `destroy` must be said,
  if only as `none`.
- **A step always has a time limit.** Orca lets a step with no `timeoutSeconds` run for
  ever. Harbor gives it the setting **A machine for each run: minutes to start one**
  (30) or **minutes to remove one** (10).
- **`checkoutMode: provisioned-root` is refused**: it needs a recipe that connects over
  SSH.

Commands are run by `sh -c` from the host app's root (`Rails.root`), as Orca runs them
from the repository's, so a path is relative to the app.

#### The contract, which is Orca's

Each step runs in a process group of its own with Harbor's own environment (that is
where a script finds its provider credentials: Harbor stores none) and Orca's variables
added:

| Variable | Value |
| --- | --- |
| `ORCA_VM_MODE` | `create` or `destroy` |
| `ORCA_VM_INSTANCE_ID` | The machine's id: `harbor-<run id>-<8 hex>`. One per run, the same every time a step runs for that run. Name the machine after it. |
| `ORCA_RECIPE_ID` | The recipe's id |
| `ORCA_WORKSPACE_NAME`, `ORCA_REPO_BRANCH` | The worktree and branch the run will get: `harbor-run-<run id>` |
| `ORCA_REPO_REF` | The branch the run starts from (`base:`), or empty |
| `ORCA_REPO_PATH` | The folder the recipe is declared in: the host app's root |
| `ORCA_RECIPE_RESULT_SCHEMA_VERSION` | `1` |
| `ORCA_PROJECT_ID`, `ORCA_WORKSPACE_ID`, `ORCA_REPO_URL`, `ORCA_REPO_REF_HEAD`, `ORCA_VERSION` | Set and empty: Orca fills them from its own project, and here there is none |

**`create`** starts a machine, makes sure the repository is on it, runs
`orca serve --port … --project-root … --pairing-address … --recipe-json` there, and
prints exactly one JSON object on stdout:

```json
{ "schemaVersion": 1, "pairingCode": "orca://pair?…", "projectRoot": "/srv/app",
  "userData": { "provider": "aws", "resourceId": "i-0abc…" } }
```

`pairingCode` and `projectRoot` (an absolute path on the machine) are required.
Progress and errors go to stderr, and each line of stderr goes to the run's log as it
arrives. Anything else on stdout spoils the result, and Harbor refuses it without
repeating what was printed. The pairing address must be one the app can reach.

**`destroy`** reads one line of lifecycle JSON on stdin and removes the machine:

```json
{ "schemaVersion": 1, "mode": "destroy", "recipeId": "aws-sandbox", "instanceId": "harbor-42-9f3a1c0e",
  "workspaceName": "harbor-run-42", "recipeResult": { "…what create printed…" } }
```

When `create` never returned a result (it failed, overran, was stopped, or the app went
down under it) there is **no `recipeResult`**, exactly as in Orca: the script finds the
machine from `instanceId`. So name the machine after `ORCA_VM_INSTANCE_ID` in `create`,
before any slow work. Exit 0 only when the machine is gone (or provably never was);
anything else keeps it on Harbor's list.

A step that runs past its limit has its whole process group stopped: TERM, then KILL
five seconds later.

What Harbor leaves out of Orca's lifecycle JSON: `projectId` and `workspaceId`, which
Orca also leaves out when it has none.

#### An example recipe

`examples/environment-recipes/` has a complete small pair, `local-orca-create.sh` and
`local-orca-destroy.sh`, whose "machine" is a second headless Orca server on the same
machine. It needs no cloud account, so it is the way to try this end to end, and it is
the shape to adapt: where it starts a process, a provider's recipe starts a machine.
Its `create`, in outline:

```bash
#!/usr/bin/env bash
set -euo pipefail
instance="${ORCA_VM_INSTANCE_ID:?}"                      # the machine's name, from the first line
state="$STATE_DIR/$instance"

# Idempotent for an instance id: a machine already up for it is the answer.
if running && parses; then emit; exit 0; fi

# Whatever goes wrong from here, nothing is left behind.
trap 'status=$?; [ "$status" -ne 0 ] && remove_everything; exit "$status"' EXIT

echo "starting $instance" >&2                            # progress: stderr, never stdout
start_the_machine                                         # provider create / run / boot
# on the machine: orca serve --port "$port" --project-root "$root" \
#                   --pairing-address "$reachable_address" --recipe-json > recipe.json &
wait_until recipe.json parses, or fail with the server's log on stderr

emit                                                      # serve's JSON + userData, one object
trap - EXIT
```

and its `destroy`:

```bash
#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"                                          # the lifecycle JSON
instance="$(ruby -rjson -e 'print JSON.parse(ARGV[0])["instanceId"].to_s' "$payload")"
[ -n "$instance" ] || { echo "no instanceId in the lifecycle payload" >&2; exit 1; }
remove_the_machine_named "$instance"                      # by its name: works with no recipeResult
```

Declared for a site to try it:

```yaml
environment_recipes:
  local-orca:
    name: Local Orca server
    create: <%= Gem.loaded_specs["harbor-engine"].full_gem_path %>/examples/environment-recipes/local-orca-create.sh
    destroy: <%= Gem.loaded_specs["harbor-engine"].full_gem_path %>/examples/environment-recipes/local-orca-destroy.sh
    timeout_seconds: { create: 120, destroy: 60 }
```

with `LOCAL_ORCA_PROJECT_ROOT` (the repository's folder) in the app's environment.
`try-with-a-local-orca.rb`, beside the scripts, does the machine's half of a run with
them from a checkout of this repository: a real `orca serve`, a worktree, a terminal,
then `destroy`. For
a cloud provider, Orca's guide has the full method (a base image with the tools and the
agent logged in, the Git token passed only at run time, the pairing address derived
from the machine's public URL) and a worked example; a recipe written with it works
here unchanged.

#### The runtime

On **New runtime**, Orca (per workspace) has one field, **Recipe**, a list of the
declared recipes, and under Advanced **The repository's setup hooks** (as the other Orca
kinds). There is no JSON. Its config is `{ "recipe": "aws-sandbox", "setup": "skip" }`.
A site with no recipe declared isn't offered the kind: the form says how to declare
one, or what is wrong with the file. The list shows the runtime as
"Orca (per workspace) · AWS sandbox".

- **Limit** is machines at once, as on any runtime.
- **Not taking work** when the recipe isn't declared any more, the file can't be read,
  or no runner address is set.
- **Check health** finds the recipe and checks that each step's script is there and
  executable. It starts nothing.
- **The runner address** (Settings) is where each machine posts the run's output, so
  it must be one a machine can reach. The runtime's page warns when it is this
  machine's own.

The machine needs what any runner machine needs (`sh`, `curl`, the agent's command line
and a login or a credential for it), `orca`, and the repository at `projectRoot`. The
app needs the `orca` command, to talk to each machine's server.

#### A run, step by step

1. **Placed.** `Harbor::AgentSession` starts the session as on any runtime. The backend
   writes a `Harbor::Machine` row for the run (its instance id, the recipe, status
   `creating`) and queues `Harbor::Machines::ProvisionJob`. It returns at once: nothing
   is run where the session was started, which may be a web request. The run is
   `running`, with no session yet (`runner_state["machine"]["phase"]` is `creating`).
2. **`create`.** The job runs the step. While it runs, the row is touched every five
   seconds and nothing is held: no lock, no transaction, no database connection.
3. **The result** is read and checked. A result that is not Orca-server mode's (no
   `pairingCode`, a relative `projectRoot`, schema version 2, **an SSH `connection`
   block**) ends the run with a message saying which, and the machine is destroyed.
   A good one is kept, encrypted, on the machine's row (below).
4. **On the machine.** With the pairing code, Harbor asks the machine's Orca for its
   status (up to five times, three seconds apart: an address can take a moment to
   answer), asks for a worktree `harbor-run-<run id>` in the repository at
   `projectRoot` (a server that doesn't know that folder yet is told about it with
   `orca repo add`, then asked again), and starts a terminal there running the run's
   command inside the runner script.
5. **An Orca session.** The session is written on the run and the run's own clock
   starts: the time `create` took is not counted against `timeout:`, and no limit or
   silent check applies while the machine is being made (`create` has its own). From
   here everything under Agent sessions holds: recording, stop, timeouts, the silent
   check, interruptions. Every Orca command for the run (stop, "is it still there?",
   starting again) goes to that run's machine with that run's pairing code.
6. **The end.** However the run ends (finished, failed, stopped, timed out, never
   started) the finisher queues `Harbor::Machines::DestroyJob`, which runs `destroy`
   with the lifecycle JSON. `destroy` never runs in the runner's request or a page's.
   The worktree isn't removed first: it goes with the machine. `keep_worktree: true`
   does not keep a machine.

A run stopped while `create` is running: the job notices at its next heartbeat, stops
`create` with everything it started, and runs `destroy` itself.

The run's capacity slots are leases sized for the timeout as first given, so after a
long `create` they can lapse before the session ends, as after an interruption.

#### Machines are not left running

A paid machine nobody knows about is the worst thing this feature can do, so every
machine is a row written **before** `create` starts, and a row is only done with when
`destroy` exited 0, when the recipe says `destroy: none`, when `create` provably never
ran, or when a person said the machine is gone. What stops each way of leaking one:

| What happens | What stops a machine being left |
| --- | --- |
| The run ends, any way at all | The finisher queues `destroy` (`run_over`), whether or not the run ever got a session. |
| `create` fails, overruns or prints something unusable | `destroy` runs with the instance id and no `recipeResult`; an object it did print is passed on. |
| `create` overruns | Its whole process group is stopped, so nothing it started carries on making a machine. |
| The run is stopped during `create` | `create` is stopped at the next heartbeat, then `destroy` runs. A queued `destroy` waits while `create` is still being stopped, so it never runs too early. |
| The app goes down during `create` | See Restarts, below: `destroy` by instance id, before anything is made again. |
| The machine's Orca never answers, or can't start the run | The run fails and `destroy` runs with the result. |
| `destroy` fails, or its job is lost | The sweep. |
| The recipe's declaration is removed while machines exist | The `destroy` command is kept with each machine when it is made, and used when the file no longer has the recipe. |
| A run with no timeout never ends | The sweep stops a run whose machine is older than **A machine for each run: longest life** (24 hours; 0 for no limit). |
| The run's row is deleted | The sweep treats a machine with no run as one whose run is over. |
| Two things remove a machine at once | One claims it; the other does nothing. |

**The sweep** (`Harbor::Machines.sweep`) looks at every machine that is not done with
and runs `destroy` for each whose run is over. One it could not remove is tried again
ten minutes later, for ever: Harbor never gives up on a machine by itself. Schedule it
like the automations tick, every few minutes:

```yaml
# sidekiq-scheduler or sidekiq-cron (config/sidekiq.yml)
:scheduler:
  :schedule:
    harbor_machines_sweep:
      cron: "*/5 * * * *"
      class: Harbor::Machines::SweepJob
```

**A site with an Orca (per workspace) runtime must schedule it.** Without it a failed
`destroy` is only tried again from the button.

**The runtime's page** has a Machines section: the machines in use (with their runs),
and the ones finished runs left behind, each with how often removing it was tried and
the last error. **Remove leftover machines** runs the sweep for that runtime now.
**Forget it** is for a machine a person has checked is gone (they removed it by hand,
or nothing was ever made): Harbor stops trying. It is refused while the machine's run
is still going. Each failure is also an error line in the app's log.

What Harbor can't see: a machine a script started and then lost track of itself (it
exited 0 from `destroy` without removing it, or `create` made two). The instance id in
the machine's name is what makes those findable at the provider.

#### Restarts

- **Mid-run.** The session is in the machine's Orca, not in the app, and what Harbor
  needs is in the database: the session on the run, the pairing code on the machine's
  row. `Harbor::AgentSession.recover!` picks the session up as it does any Orca
  session, and a session whose terminal has gone is started again **on the same
  machine**, in the same worktree. If the machine itself doesn't answer, it is asked
  again every minute for ten minutes; after that the machine is destroyed and the run
  starts over on a new one.
- **During `create`.** The step dies with the worker (a job stopped by its worker
  shutting down stops the step's process group itself), and its heartbeat stops. After
  90 seconds without one the run is no longer "being set up", the silent check finds
  it has no terminal, and it is started again like any session cut off while starting.
  Before `create` runs again, Harbor stops whatever is left of the old step's process
  on this machine (matched by its process id and start time), then runs **`destroy`
  with the instance id and no result**. Only when that exits 0 does `create` run again,
  **under the same instance id**. If `destroy` fails, no second machine is made: the
  run ends as an error and the machine stays on the list for the sweep and for a
  person. Harbor does not rely on `create` being idempotent, because it can't know
  that it is; a recipe that follows Orca's advice and is idempotent per instance id
  loses nothing by this.
- **During `destroy`.** The claim on the machine lapses after the step's time limit
  and a minute, and the sweep runs it again.
- **Between `create` returning and the terminal starting.** The machine is recorded as
  up before Orca is asked. A job run twice does nothing the second time; a run started
  again in this state destroys the machine and makes a new one.

#### Where the pairing code is kept

A machine's pairing code controls the machine. It is kept in one place: the
`sealed_result` column of the machine's row in `harbor_machines`, which holds what
`create` printed, encrypted with a key derived from the app's `secret_key_base`
(`ActiveSupport::MessageEncryptor`). It has to be kept while the machine may be up,
because the app must reach the machine after a restart and `destroy` is handed
`recipeResult`. The column is emptied when the machine is done with (destroyed,
`destroy: none`, or forgotten); a machine whose `destroy` failed keeps it until one
works.

It is not on the run (`runner_state`, `input`, `output`), not in a job's arguments,
not in a log, an event, a page or an error. A script that prints it on stderr has it
replaced with `[pairing code]` before the line reaches the run's log (anything shaped
`orca://…`, and the code itself once known), and the same is done to what Orca answers
and to a failed `destroy`'s last words. The model filters the column from `inspect`.
Two places it does pass through: the `destroy` script's stdin, as Orca's contract has
it, and the argument list of each `orca` command while it runs (`--pairing-code`),
which other users of the app's own machine could read with `ps`.

If `secret_key_base` changes while a machine is up, its result can no longer be read:
the run's later Orca calls fail, and `destroy` is given the instance id only.

#### Not supported yet

- **SSH mode.** A recipe that returns a `connection` block is refused with a message
  saying so. Only recipes that start an Orca server and return its pairing code run.
- **`checkoutMode: provisioned-root`** (it is SSH mode's).
- **`suspend` and `resume`.** Read from the file and checked; never run. A machine
  lives for its run.
- **Keeping a machine for follow-up work.** The backend answers `keeps_workspaces?`
  with false.
- **A check that the sweep is scheduled.** Harbor can't tell; the page says what it
  found, not whether anything is looking.

## Agent sessions

An agent session is one run of an AI coding agent's command line, `claude -p`
for an Anthropic model or `codex exec` for an OpenAI one, as the command in an
Orca terminal. Only HTTP passes between the machine it runs on and the app.
(On an Orca (per workspace) runtime the terminal is on a machine made for the run:
see A machine for each run. On a Conductor Cloud runtime the agent runs in a cloud workspace instead and
Harbor asks how it is doing; everything in this section that speaks of a
terminal, a runner or a worktree is different there, as Conductor Cloud above
says.)
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

## Workflows

A workflow is a trigger and a graph of steps: agents, verdicts, actions, approvals,
branches and loops, each step's output feeding the next. People build one in a
visual builder; every save is a new version; a run walks the version it started
on, and every step that does work is a tracked Run.

### The records

| Record | Table | What it is |
|---|---|---|
| `Harbor::Workflow` | `workflows` | A key, a name, a `mode` (`off`, `dry_run`, `live`), the flows it `claims`, and its current version |
| `Harbor::WorkflowVersion` | `workflow_versions` | One saved definition, numbered, never changed |
| `Harbor::WorkflowRun` | `workflow_runs` | One firing: its status, mode, what started it, its `context`, and what it is about |
| `Harbor::WorkflowStepRun` | `workflow_step_runs` | One execution of one step: its input, output, status, and the `Run` that did the work |
| `Harbor::WorkflowWait` | `workflow_waits` | Something a parked step is waiting for, with when it gives up |

A workflow run is its own record and not a Run because it lives as long as the
flow does, hours or days; `runs.workflow_run_id` ties each step's Run to it.
`workflow.save_definition!(json_or_hash, user:)` returns `[version, errors]`: a new
version when the definition is valid and changed, the current one when it didn't,
and the reasons when it isn't valid. Each saved version is also handed to
`config.export` as `workflows/<key>.json`.

A host with more on a workflow or a run subclasses the record and names it
(`c.workflow_class = "Workflow"`, `c.workflow_run_class = "WorkflowRun"`). With
`c.user_class = "User"` a version records who saved it and a run who started it.

### A definition

```json
{
  "settings": {},
  "inputs":   [ { "key": "branch", "description": "the branch to tidy" } ],
  "triggers": [ { "kind": "manual" } ],
  "steps": [
    { "key": "review", "type": "verifier", "agent": "task:review", "prompt": "Review {{input.branch}}",
      "verdicts": [ "approve", "changes" ] },
    { "key": "route", "type": "choice", "branches": [
        { "name": "Needs work", "when": { "path": "steps.review.verdict", "op": "eq", "value": "changes" },
          "steps": [ { "key": "fix", "type": "agent", "agent": "writer", "prompt": "Fix: {{steps.review.feedback}}" } ] } ],
      "otherwise": [] },
    { "key": "ok", "type": "approval", "prompt": "Merge {{input.branch}}?" }
  ],
  "finally": [ { "key": "done", "type": "action", "action": "note", "message": "{{steps.ok.decision}}" } ]
}
```

Steps run top to bottom; `choice` and `loop` nest steps; `finally` runs at the end
however the main path ended. A step's `key` names its output for later steps. Text
fields are templates over one flat context: `trigger.*` (what started the run),
`input.*`, `settings.*`, `steps.<key>.*` (each step's output, plus `status`),
`loop.<key>.iteration` and `run.*` (`id`, `url`). A placeholder that names nothing
stays as written, so a typo shows. Conditions are data, never code: a leaf is
`{ "path", "op", "value" | "values" }` with `eq ne in not_in contains present blank gt
gte lt lte`, combined with `all`, `any` and `not` (`Harbor::Workflows::Condition`).
On any step, `"on_error": "continue"` carries on past a failure.

Harbor's own step types need no host:

| Type | What it does |
|---|---|
| `agent` | Runs an agent as an agent session (see Agent sessions), a tracked Run. `agent` is an agent's key, or `task:<task type>` for whoever that task is given to. A `prompt` or a `slash_command`; `outputs` names values it must return; `session: "continue"` picks up the step's previous pass; `timeout_minutes` |
| `verifier` | The same, and it must return one of `verdicts` (as `{"verdict": …, "feedback": …}` in a fenced `json` block, or a `VERDICT:` line) |
| `action` · `note` | Writes a line to the app's log |
| `filter` | Stops the run there, as succeeded, unless `when` passes |
| `choice` | Runs the first branch whose `when` passes, else `otherwise` |
| `loop` | Runs its steps again `until` a condition passes, at most `max_iterations` (20 at most) |
| `approval` | Waits for a person to approve or reject on the run's page |
| `call` | Starts another workflow with this run's trigger and its own `input`, and waits for it |

and one trigger, `manual`: started from the workflow's page, or by a `call` step.

### The engine

`Harbor::Workflows.start!(workflow, trigger:, kind:, input:)` makes the run and
queues `Harbor::Workflows::AdvanceJob`, the only thing that moves a run forward.
The engine (`Harbor::Workflows::Engine`) replays the definition from the top on
every advance: a step with a recorded step run isn't run again, its output goes
back into the context, and the first step that hasn't run is started. A step that
finishes on the spot lets the walk go on; one that has to wait (an agent's Run, a
person, a called workflow) stops it, and whatever finishes that step queues the
job again. Everything the walk needs is in the database, so a restart loses
nothing and a double enqueue is harmless.

An agent step's Run is started by `Harbor::Workflows::AgentStepJob`; while the
agent or every runtime is full, or no model is available, the Run waits and the
job comes back (the **Agent step retry** setting says how soon). When a Run that
is a workflow step finishes, however it finishes, its result becomes the step's
output (`Harbor::Workflows::StepCompletion`) and the run moves on.

**Modes.** A run is live only when its workflow is `live` and the **Workflows**
setting is on; otherwise it is a dry run, which records what each step would do
and runs only the steps registered as having no side effect. `off` only means
nothing starts the workflow on its own: a person can still dry-run it.

**Control** (`Harbor::Workflows::Control`): `cancel!(run, user:)` cancels the
pending steps, stops their Runs and still runs `finally`; `decide!` answers an
approval; `rerun!` starts again with the same trigger and input.

### Starting a workflow from host code

```ruby
workflow = Harbor::Workflow.find_by!(key: "tidy-branch")
run = Harbor::Workflows.start!(workflow,
  trigger: { "kind" => "ticket", "queue" => "support", "sender" => "sam" },   # what steps read as trigger.*
  kind: "ticket",                                # the trigger's kind
  input: { "branch" => "main" },                 # what steps read as input.*
  user: current_user,                            # who started it, if someone did
  subject: { repo: "acme/app", pr_number: 12 },  # what it is about; optional
  webhook_event: event, dedupe_key: "tidy:#{event.delivery_id}")   # optional
```

It returns the run, or `nil` when it wasn't started: the workflow has no saved
version, the dedupe key was already used, or a run of the same workflow about the
same subject is still going (one active run per workflow per subject). A subject
is a repository with a pull request or an issue number; `c.workflow_subject` derives
one from the trigger and the input when none is given, and a host's run class says
where it lives (`subject_url`). A host that starts workflows from webhooks decides
which workflows a delivery starts (`workflow.definition.triggers` with
`Harbor::Workflows.trigger_matches?`) and calls `start!` for each.

### Registering a step type and a trigger

Everything a workflow can be built from is one registered list
(`Harbor::Workflows`), read by validation, the engine, the builder's palette and
forms, and the reference page:

```ruby
# config/initializers/harbor.rb
Harbor::Workflows.register_step "action", action: "chat.post",
  label: "Post to chat", group: "Chat", icon: "message", color: "#4A154B",
  description: "Posts a message to the team's channel.",
  fields: [ { name: "body", label: "Message", kind: "textarea", required: true } ],
  outputs: [ [ "url", "string", "link to the message" ] ],
  defaults: { "body" => "" },
  runner: "Chat::PostStep",                       # named, and looked up when a step runs
  validate: ->(step, label) { step["body"].blank? ? [ "#{label}: say something" ] : [] },
  summary: ->(step) { step["body"].to_s.truncate(60) }

class Chat::PostStep
  # Finish the step run and return :done, or leave it pending and return
  # :blocked; whatever finishes it later calls Harbor::Workflows.advance_later.
  def self.start(engine, step, step_run, input)
    message = Chat.post(input["body"])
    step_run.finish!(status: "ok", output: { "url" => message.url })
    :done
  end
end

Harbor::Workflows.register_trigger "ticket",
  label: "Ticket", group: "Desk", icon: "tag", color: "#0F766E", description: "A ticket was opened or changed.",
  fields: [ { name: "queue", label: "Queue", kind: "text", required: true } ], defaults: { "queue" => "support" },
  validate: ->(trigger, label) { trigger["queue"].blank? ? [ "#{label}: name a queue" ] : [] },
  summary: ->(trigger) { "Ticket in #{trigger['queue']}" },
  matches: ->(trigger, event, data) { data["queue"] == trigger["queue"] }

Harbor::Workflows.register_data :trigger, "queue", "string", "the ticket's queue"   # the data picker and reference
Harbor::Workflows.register_setting "channel", label: "Channel", kind: "text", help: "Where it posts."
Harbor::Workflows.register_validator ->(definition) { [] }      # rules that span steps
Harbor::Workflows.register_claim "triage", "New tickets → TriageJob"   # a flow in code a live workflow takes over
```

A type is `"agent"`, or `"action"` with an `action:` (its id is then
`"action:chat.post"`). `before:` and `after:` place an entry beside another;
registering an id again replaces that entry where it is, `update_step` and
`update_trigger` change part of one, and `remove_step` and `remove_trigger` take
one of Harbor's away, so a host that runs agents its own way registers its own
runner for `agent` and `verifier`. A step's other options: `side_effect: false`
(runs in a dry run too), `working: true` (a run is "running", not "waiting", while
it is pending), `dry_run_stop:` (a dry run ends there), `inside_loop: false`,
`gate:` and `gate_note:`, `dynamic_outputs:`, `makes_workspace:`, `short:` and
`pill:`. Anything read from the database or from the host's classes (a select's
options) may be a callable, called each time it is needed, so registering loads
nothing early. Field kinds the builder edits: `text`, `template`, `textarea`,
`number`, `bool`, `select`, `multi`, `condition`, `agent`, `workflow`, `workspace`,
`kv`.

A host's step that waits for something creates a `Harbor::WorkflowWait` on its
step run and returns `:blocked`; when the thing happens the host finishes the step
run, destroys the wait and calls `Harbor::Workflows.advance_later(run.id)`.
`Harbor::Workflows.sweep_waits!`, called on a schedule, finishes the ones past
their `expires_at` as timed out.

### The pages and the builder

Under `Harbor.path`, gated by the Workflows page switch: **the list**
(`/factory/workflows`, each workflow with what is running and how its last three
runs ended), **a workflow's page** (its canvas, mode, runs, versions and "Run
it"), **the builder** (`/factory/workflows/new`, `…/:key/edit`), **the reference**
(`/factory/workflows/reference`, printed from what is registered), **recent runs**
(`/factory/workflow_runs`) and **a run's page** (`/factory/workflow_runs/12`: the
canvas with each step's status, and a panel with a step's input, output and live
log, the step list, or the run's context; Cancel, Run again, and Approve or Reject
on an approval). A run's page refreshes itself while the run is live.

The builder is one Stimulus controller (`harbor--workflow-builder`) that draws the
canvas from the catalog (`Harbor::Workflows::Catalog`); it knows no step type or
trigger by name beyond the three the engine walks itself. Its styles are in
`app/assets/tailwind/harbor/workflows.css`, which Harbor's stylesheet imports;
they are coloured with the host's theme (`--color-ink`, `--color-soft`,
`--color-hairline`, `--color-bone`, `--color-brand`, …), each with a value of its
own for a host that has none.

### What a host adds

Partials in the host's `app/views/harbor/workflows/`. Harbor has words of its own
for the first four, which a host's file of the same name replaces; the rest are
rendered when they exist.

| Partial | Where |
|---|---|
| `_intro` | The list's introduction |
| `_switched_off` | The notice while the Workflows setting is off |
| `_empty` | The list with no workflows yet |
| `_run_fields` | What "Run it" asks for (Harbor's: the input as JSON), read by `c.workflow_manual_start` |
| `_index_actions` | Buttons beside "New workflow" |
| `_form_extras` (`form`) | Fields in the builder's settings panel, saved when named in `c.workflow_params` |
| `_versions_note` (`workflow`) | Under a workflow's versions |
| `_reference_triggers` | Under the triggers on the reference page |

```ruby
# config/initializers/harbor.rb
Harbor.configure do |c|
  c.workflow_class = "Workflow"            # the host's subclasses of the records
  c.workflow_run_class = "WorkflowRun"
  c.user_class = "User"                    # who saved a version, who started a run
  c.workflow_params = %i[owner]            # the host's attributes the workflow form may save
  c.workflow_starter = -> { { "triggers" => [ { "kind" => "manual" } ], "steps" => [ … ] } }   # what a new workflow opens on
  c.workflow_subject = ->(trigger, input) { { repo: trigger["repo"], pr_number: input["pr"] } }
  c.workflow_manual_start = ->(params, user, input) { [ { "kind" => "manual", "ticket" => params[:ticket] }, input ] }
  c.workflow_event_data = ->(event) { Desk.trigger_data(event) }   # with it, a workflow's page offers "Test with an event"
  c.workflow_run_url = ->(run) { "https://hub.example.com/factory/workflow_runs/#{run.id}" }
  c.workflow_run_finished = ->(run) { Desk.note_finished(run) }    # a run has finished, cleanup and all
  c.workflow_step_retry = ->(run, step_run) { Retries.schedule(run, step_run) }   # true: the host runs the step again
  c.workflow_run_cancel = ->(run, user) { Runs.stop(run) }         # stop a step's Run when its workflow is canceled
end
```

Without `workflow_run_url`, a run's address is its page's path after the **Runner
address** setting. Without `workflow_run_cancel`, a step's Run is stopped the way
the Runs page's Stop does.

## Scorers

A `Harbor::Scorer` is a judge over finished agent runs: one question you write ("Did the
agent run the tests before opening the PR?"), a list of labels each carrying a score from
0 to 1, and a threshold a run's score has to reach to pass. A scorer applies to every
agent run, or only to the agents and task types it names. A share of the runs it applies
to (`sample_rate` %) is judged when they finish; any run can be judged by hand.

A `Harbor::ScorerResult` is one scorer's verdict on one run: the label the judge chose,
its score, whether that passes, and the judge's reasoning. Judging a run again replaces
the row. The judge itself is a `Run`, a child of the run it grades (`skill` "scorer",
`result.judge_run`), so its model, cost, log and outcome are kept like any run's. A run a
scorer can judge is `run.scorable?`: a top-level agent run that ended `ok`, `error` or
`timeout` and kept a transcript (`raw_log_path`).

Two jobs do the work. `Harbor::Scorers::SampleJob` runs when a scorable run finishes and
queues a judge for each enabled scorer that applies and whose sample rate picks it.
`Harbor::Scorers::EvaluateJob` judges one run with one scorer: it makes the judge run and
the result, asks the judge, reads the verdict out of the answer
(`Harbor::Scorers::Verdict`) and records it. One judge holds a scorer and run at a time
(`Harbor::ScorerResult.claim!`), so a double click, a replayed request and the sampler
can't start two.

### The judge

**Harbor does not run the model that judges.** Running one over a transcript safely is
specific to a site: the transcript has to reach wherever the model runs, and the model
has to be kept to that one file, because a transcript can carry text written by anyone
who could comment on the work. Harbor's own way of running an agent (Agent sessions)
starts a named agent in a checkout of a repository and fetches a fixed set of files, so a
judge built on it would see the repository and not the transcript. Until Harbor has a
confined judge of its own, the host supplies it:

```ruby
# config/initializers/harbor.rb
Harbor.configure do |c|
  c.scorer_judge = ->(judgement) do
    choice = judgement.scorer.model_alias.resolve          # the model to judge with
    judgement.judge.update!(model: choice.model, command: "my-judge --model #{choice.model}")
    judgement.judge.start!
    judgement.log("judging run ##{judgement.run.id} with #{choice.model}")
    MyJudge.read(judgement.transcript_file, prompt: judgement.prompt(transcript: "transcript.ndjson"), model: choice.model)
  end
  c.scorer_judge_wait = 15.minutes   # longer than a judge ever takes
  c.site_name = "Acme Factory"       # "grading one finished agent run for Acme Factory"
end
```

The hook is called with a `Harbor::Scorers::Judgement`:

| | |
|---|---|
| `scorer`, `run` | The scorer, and the run being graded |
| `judge` | The judge's own run. Put its model, command, cost and tokens on it |
| `result` | The `ScorerResult` the verdict will be written to |
| `prompt(transcript:)` | What to ask the model: the run, the scorer's question, its labels and the shape of the answer. `transcript` is the transcript's file name as the model will find it in the directory it runs in |
| `transcript_file` | The graded run's transcript on this machine (`run.raw_log_file`) |
| `log(line)` | Writes a line to the judge run's live log |
| `attempt` | How many times this judgement has been put off as busy |

and ends one of these ways:

- **It returns the model's final text.** Harbor reads the verdict from it: the last
  fenced JSON block (or bare object) whose `classification` is one of the scorer's labels.
  The result becomes `ok`, with the label, its score, pass or fail and the reasoning, and
  the judge run finishes `ok`. Text with no usable verdict is an error on both.
- **It calls `judgement.answer!(text, output: { … })` itself**, to add to what the judge
  run keeps as its output, and returns nothing.
- **It calls `judgement.fail!(message, status: "error")`** when it can't judge: nothing
  to read, the judge switched off. `status` is how the judge run ends (`"error"`,
  `"skipped"`, `"timeout"`, `"canceled"`); the result is an error with the message.
- **It raises `Harbor::Scorers::Judgement::Busy`** when it can only take so many at once.
  The job runs again in two minutes, up to ten times, with the claim still held.
- **It returns nothing and answers later**, when what it started reports back:
  `Harbor::Scorers::Judgement.for(judge_run)&.answer!(text)`. Until then the verdict
  shows as pending. A judgement pending longer than `scorer_judge_wait` can be claimed by
  another.
- **It raises anything else.** The message is the error on both, and the job doesn't die.
  A model alias with nothing available (`Harbor::ModelAlias::Unavailable`) ends the judge
  run `skipped`.

With no `scorer_judge`, the pages all work and nothing is judged: no run is sampled, the
Scorers page says so, and scoring a run by hand ends as an error on the result and the
judge run naming the setting.

### The Scorers pages

Under `Harbor.path` like the rest, in `Harbor::ScorersController`: **the list**
(`/factory/scorers`), with each scorer's question, what it judges, its judge, sample
rate, pass rate over thirty days and its on/off switch; **a scorer's page**
(`/factory/scorers/3`), with its pass rate week by week, its instructions and labels and
its last fifty verdicts, each linked to the run and the judge's run; and **the form**
that creates and edits one. A scorer is a card on a phone.

**A run's page** shows what the scorers made of it, between its details and its log:
each verdict with its reasoning, the judge's run, the proposal that reviewed it, and
"Score now" (`POST /factory/runs/12/score`, with `scorer_id` for one scorer or without
for every one that applies). While a verdict is pending the page refreshes itself.

A host with more on its scorers subclasses the record and names it
(`c.scorer_class = "Scorer"`). Two class methods are meant to be overridden:
`Scorer.task_types`, the task types the form offers (Harbor's are the declared ones), and
`Scorer.draft`, what the New scorer form starts with (a model alias, say).

One part of the form is a partial a host can replace with its own, by having a partial of
the same name in its `app/views/harbor/scorers/`:

| Partial | Harbor's |
|---|---|
| `_self_improvement_note.html.erb` | What ticking Self-improvement does, beside the checkbox: failures become proposals to change the agent's instructions |

## Proposals

A `Harbor::Proposal` is a change drafted from a batch of one scorer's failures on one
agent, with the runs behind it. Nothing is adopted without a person. Harbor's own
targets are text it holds, each kept as it was and as proposed:

| `target_kind` | Changes | Applied |
|---|---|---|
| `agent_prompt` | The agent's system prompt | On the page, with a click (`proposal.apply!(by: user)`) |
| `agent_document` | One of the agent's documents (`document_path`), created if new | The same |

Applying refuses when the text has changed since the proposal was made. A proposal is
`proposed`, then `applied` or `dismissed`.

### Where proposals come from

A scorer with **Self-improvement** ticked has its failures collected.
`Harbor::Proposals::CheckJob` groups each such scorer's unreviewed failures by agent, and
hands a group over once it has `improvement_min_failures` of them, or one older than
`improvement_max_age_days`; a check a person started takes any group. A group is claimed
as it is handed over, so two checks never hand over the same failure, and is at most
`Harbor::Proposals::BATCH` (25) failures. The check runs as a `Run` made beforehand:
`CheckJob.perform_later(run.id)`. "Run the check now" on the Proposals page does that; so
does a schedule of the host's.

**Harbor does not run the agent that drafts**, for the reason it doesn't run the judge:
that run reads transcripts, so it has to be read-only in a way a site decides. The host
supplies the drafter, and hands its answer back:

```ruby
# config/initializers/harbor.rb
Harbor.configure do |c|
  c.proposal_drafter = ->(scorer:, agent_key:, result_ids:, check_run:) do
    DraftProposalsJob.perform_later(scorer.id, agent_key, result_ids, check_run.id)
  end
end

# In that job, when its read-only agent run has finished ok:
results = Harbor::ScorerResult.where(id: result_ids, reviewed_at: nil).includes(:run)
Harbor::Proposals::Recorder.call(run: run, scorer: scorer, agent: agent, results: results, text: final_text)
# …and when it didn't, so the next check takes the failures again:
Harbor::Proposals::Recorder.release!(results)
```

The answer `Recorder` reads is the last fenced JSON block holding a `proposals` list
(`Harbor::Proposals::Verdict`):

```json
{"pattern": "<the shared cause>",
 "proposals": [
   {"target": "agent_prompt", "summary": "<one line>", "after": "<the full new system prompt>"},
   {"target": "agent_document", "path": "<document path>", "summary": "<one line>", "after": "<the full new body>"}
 ]}
```

Each entry becomes a proposal with the text as it is now, the runs and results it was
drafted from (`evidence`) and the pattern; an entry that changes nothing is dropped. The
failures the run was shown are marked reviewed (`reviewed_at`, `proposal_id`), and the
run's output names the proposals. An empty list is an answer too: the failures are
reviewed and nothing is proposed. With no such block the run is finished as an error and
the failures are released. Writing the prompt for that run is the host's.

With no `proposal_drafter`, the pages work, the page offers no "Run the check now", and a
check ends as an error naming the setting, having claimed nothing.

### A host's own targets

A host whose proposals reach further than an agent's text (a file in a repository, a page
of a handbook) registers the target:

```ruby
# config/initializers/harbor.rb
Harbor::Proposals.register_target "handbook_page",
  label: ->(proposal) { "handbook · #{proposal.document_path}" },
  build: ->(entry, draft) { { document_path: entry["path"], after: entry["after"] } if entry["after"].present? }
```

`label` is what the target is called on the pages (text, or a callable given the
proposal). `build` is called when a drafting run's answer has an entry with this target:
it is given the entry and the draft (`run`, `scorer`, `agent`, `results`, `pattern`,
`evidence`) and returns the proposal's attributes beyond scorer, agent, run, target and
summary, or nil to record nothing. An entry is untrusted text: check it there. A target
with no `build` is only ever recorded by the host. Harbor lists and shows a proposal of a
host's kind and offers Dismiss; what else can be done with it is the host's, through the
partials below.

### The Proposals pages

In `Harbor::ProposalsController`: **the list** (`/factory/proposals`), by status with a
count of each; and **a proposal's page** (`/factory/proposals/7`), with the change line
by line, what it addresses, the failed runs behind it, and **Apply** and **Dismiss**
(`POST …/apply`, `POST …/dismiss`). "Run the check now" is `POST /factory/proposals/check`.

A host adds to the pages with partials in its own `app/views/harbor/proposals/`, rendered
where the page has a place for them, when the file exists:

| Partial | Where | Locals |
|---|---|---|
| `_proposal_badges.html.erb` | The list, after a proposal's summary: a mark of the host's own | `proposal` |
| `_show_actions.html.erb` | A proposal's page, between Apply and Dismiss: the host's buttons for its own kinds | `proposal` |
| `_show_extras.html.erb` | A proposal's page, below the buttons: whole sections | `proposal` |
| `_change.html.erb` | A proposal's page, in place of the diff, for a proposal that isn't one of Harbor's kinds: a whole section showing what it would change | `proposal` |

and replaces three of Harbor's with its own of the same name:

| Partial | Harbor's | Locals |
|---|---|---|
| `_intro.html.erb` | The sentence under the heading saying what a proposal is | |
| `_index_actions.html.erb` | "Run the check now", when there is a drafter | |
| `_guide.html.erb` | "How to use this page" (it renders `harbor/shared/quality_guide`) | `proposals`, `status` |

A button in a partial posts to a route of the host's, which can sit at the same address:

```ruby
# config/routes.rb, above the engine's mount
scope Harbor.path do
  resources :proposals, only: [] do
    member { post :publish }
  end
end
```

A host with more on its proposals subclasses the record and names it
(`c.proposal_class = "Proposal"`). `proposal.applied_by_name` is meant to be overridden:
Harbor keeps the id of the host's user who applied a proposal (`applied_by_user_id`) and
has no user to ask for a name.

The Scorers and Proposals pages, and a host's Review policy page if it has one in the
menu, each start with the same guide to how they fit together
(`render "harbor/shared/quality_guide", current: :scorers, steps: […]`), which lists the
ones this site has switched on.

## Review policy

The review policy is the rules a site reviews pull requests by, and the record of each
review. **Harbor keeps the records, checks what a rule says and serves the pages. It does
not run reviews itself yet.** Deciding which rules a pull request owes, running the
checks, reading the code and publishing the result is the site's own code, which writes
rounds and their checks into Harbor's records; the pages then show them. A site with no
code of its own can write and version its rules today, and sees rounds as soon as
something records them.

### The records

Harbor's migration creates the six tables.

- **`Harbor::ReviewRule`** (`review_rules`): one rule. Its `kind` is `risk` (what kind of
  change a pull request is), `check` (a piece of evidence that kind of change owes) or
  `signoff` (a person who must approve). Its `mode` is `live` (it counts), `shadow` (it
  runs and is recorded, and affects nothing) or `off`. `repo` is the repository it is
  for, or `*` for every one; `key` is unique within a kind and repository.
- **`Harbor::ReviewRuleVersion`** (`review_rule_versions`): one saved definition of a
  rule. Every save is a new version and none is ever edited, so a check run can name the
  version it ran and a bad edit is one click back. `rule.save_definition!(hash, user:)`
  returns `[version, errors]` and saves nothing when there are errors or when nothing
  changed; `rule.roll_back_to!(number)` saves an earlier definition as the newest
  version. `rule.definition` is the current one.
- **`Harbor::ReviewRound`** (`review_rounds`): one review of a pull request at one head
  commit: `repo`, `pr_number`, `head_sha`, `round`, its `phase` (`triage`, `evidence`,
  `gate`, `review`, `signoffs`, then `published`, `cancelled` or `failed`), and what the
  review found, as JSON the site fills in: `risks` (each with `key` and `reasons`),
  `gaps`, `gate` (`result`, `blocking_failures`), `signoffs` (each with `name`, `who`,
  `message`, `status`) and `review` (`verdict`, `tldr`, `findings`, `why`). The database
  allows one unfinished round per pull request. `round.cancel!(reason:)` cancels it and
  the checks still under way.
- **`Harbor::ReviewCheckRun`** (`review_check_runs`): one check in one round: the rule
  and the version it ran, its `status` (`queued`, `running`, `passed`, `failed`,
  `errored`, `skipped`, `reused`, `cancelled`), `summary`, `outputs`, `routed`, progress,
  the run that did the work (`run_id`) and, when an earlier result was reused, the check
  run it came from.
- **`Harbor::ReviewFeedback`** (`review_feedbacks`): one signal about a review's output
  (`useful`, `noise`, `accepted`, `overridden`) on a check or a kind of finding.
  `Harbor::ReviewFeedback.precision_by("check")` rolls them up per key.
- **`Harbor::ReviewEscape`** (`review_escapes`): a bug that got through, with the round
  that approved it.

`Harbor::Reviews::Document.for(round)` is the round as one Hash (its checks, progress,
cost, risks, sign-offs and review): what the round's page shows and what its `.json`
address serves. `Harbor::Reviews::Document.title(doc)` is where the round is in a line
("Evidence 2 of 5 · 40%", "Approved"). The cost counts the runs of the round's checks,
and the run the site names in the round's `input` as `code_review_run_id`.

Every saved version is also handed to `config.export`, when the host has one, as
`reviews/<kind>s/<repo>/<key>.json` (`Harbor::Reviews::Export`).

### A rule's definition

A definition is JSON, checked by `Harbor::Reviews::RuleDefinition` before it is saved.

```json
{ "label": "risk: billing", "description": "Money moves.",
  "detector": { "paths": ["(\\A|/)app/billing/"], "patch": ["update_all"], "words": "refund" } }
```

A **risk** has a `label` and a `detector`: regular expressions over the changed paths
(`paths`), over the patch (`patch`) and over the pull request's words (`words`), at least
one of them; or `{ "builtin": name }`, a detector that is the site's own code and that it
declared (below).

```json
{ "description": "No page gets slower.", "mitigates": ["perf"], "kind": "command",
  "run": { "command": "bin/page-budgets --json" },
  "outputs": [{ "name": "pages_over", "type": "list" }],
  "pass_when": { "path": "outputs.pages_over", "op": "blank" },
  "then": [{ "when": { "path": "outputs.pages_over", "op": "present" }, "action": "note", "message": "Pages over budget" }],
  "gate": "blocking", "stage": "evidence", "watch_paths": ["app/views/**"] }
```

A **check** names the risks it `mitigates` (`"*"` for every pull request), its `kind`
(`ci` with `run.job`, `command` with `run.command`, `agent` with `run.prompt`), its
`outputs` (each a `name` and a `type`: `bool`, `number`, `string`, `list`, `object`),
`pass_when` (a condition, or `exit_zero`, `ci_success` or `agent_verdict`; the default
for its kind when left out), `then` rows (an `action` of `block`, `note`, `signoff`,
`run` or `tell_reviewer`, with a `when`), a `gate` (`blocking` or `advisory`), a `stage`
(`evidence`, `after_approval` or `after_deploy`) and `watch_paths`, path globs
(`Harbor::Reviews::Glob`: `**/`, `**`, `*`, `?`, `{a,b}`).

A condition (`Harbor::Reviews::Condition`) is a leaf, `{ "path", "op", "value" }` with
`op` one of `eq ne in not_in contains present blank gt gte lt lte`, or leaves combined
with `{ "all": [...] }`, `{ "any": [...] }` and `{ "not": {...} }`. Harbor checks one and
puts it in words; deciding whether it holds for a check's outputs belongs to what runs
the check.

```json
{ "who": ["sam"], "message": "Approve the schema change", "when": { "paths": ["(\\A|/)db/migrate/"] } }
```

A **sign-off** names `who` and a `message`, and `when` it applies (`risks`, `paths`); a
check's `then` row can also ask for it.

### The pages

Under `Harbor.path` like the rest, behind the "Review policy" entry in the menu and its
switch on the Settings page (`page_reviews`):

- **The policy** (`/factory/reviews`, `harbor.reviews_path`): one row per risk with the
  checks that mitigate it and the sign-offs it triggers, a red "gap" where a risk has no
  check, the checks every pull request gets, the sign-offs, and the 25 most recent
  rounds.
- **A rule** (`/factory/reviews/rules/7`): what it says in words, a check's recent
  results and pass rate (and, in shadow, how many it would have blocked), and its last
  20 versions with "Roll back to this" (`POST …/rules/7/rollback?number=2`).
- **The form** (`…/rules/new?kind=check`, `…/rules/7/edit`): kind, key and repository
  (set once), name, mode and the definition as JSON. A new rule starts in shadow with a
  definition for its kind that can be saved as it is. What can't be saved is shown again
  with why.
- **A round** (`/factory/reviews/rounds/12`): its checks with their status, summary and
  run, why they were asked for, the sign-offs, the review, and the document. It
  refreshes itself while the round is unfinished. `/factory/reviews/rounds/12.json` is
  the document.
- **The dashboard** (`/factory/reviews/dashboard?days=30`): rounds, pull requests,
  rounds per pull request, what the checks cost, the median time to approval, how many
  results were reused, each check's runs, cost, results and precision, evidence cost by
  risk, feedback by kind of finding, and escaped bugs.

### What a host declares and configures

All optional:

```ruby
# config/initializers/harbor.rb
Harbor::Reviews.detector "risk: migration"
Harbor::Reviews.finding_category "caching"

Harbor.configure do |c|
  c.review_rule_class = "ReviewRule"                 # the host's subclass of Harbor::ReviewRule
  c.review_rule_version_class = "ReviewRuleVersion"  # and of Harbor::ReviewRuleVersion
  c.review_document_schema = "acme.review/v1"
  c.review_pull_request_url = ->(repo, number) { "https://git.example.com/#{repo}/pulls/#{number}" }
  c.review_rule_preview = ->(rule, definition, user:) { RulePreviewJob.start(rule, definition, user:) }
  c.review_rule_preview_sample = "the last 50 merged pull requests"
  c.review_cost = ->(since) { Run.where(task_type: "code_review", created_at: since..).sum(:cost_usd_actual).to_f }
end
```

- **`Harbor::Reviews.detector`**: a way of spotting a risk that is the host's own code. A
  risk may name it as `{ "builtin": name }`; one that names a detector nobody declared
  is refused.
- **`Harbor::Reviews.finding_category`**: a kind of finding the host records feedback
  under (`subject_kind: "finding"`). The dashboard lists the declared ones; with none
  declared it lists every kind that has feedback.
- **`review_rule_class`**: a subclass on the same table. Two class methods it can
  override: `page_defaults` (what a new rule starts with on the form, such as its
  `repo`) and `definition_template(kind)` (the definition a new rule of that kind starts
  with).
- **`review_rule_version_class`**: a subclass on the same table. `created_by_user_id` is
  set from whoever saved the version; a host whose users are records declares the
  association and overrides `author_label`, which the rule's page shows beside the
  version.
- **`review_document_schema`**: what the round's document calls its format
  (`harbor.review/v1` unless set), for whatever reads the `.json` address.
- **`review_pull_request_url`**: called with (repository, number); the address of that
  pull request. Without it a round's page names the pull request and doesn't link it.
  A rule for every repository passes `"*"`.
- **`review_rule_preview`**: called with (rule, definition, `user:`) when someone asks
  what a risk or a sign-off would have matched, as saved or as being edited. It starts a
  run that tries it on recent pull requests and returns the run; the rule's page shows
  the run's output when it finishes: `message`, and `matches`, each with `number`,
  `title` and `reasons`. Without it the pages have no Preview buttons, and a request for
  one starts nothing and says so. `review_rule_preview_sample` is what the buttons say
  it is tried on.
- **`review_cost`**: called with a time; what the reviews themselves (reading the code,
  not the checks) have cost since then, in dollars, shown on the dashboard as "Code
  review". Without it the tile is left out.

Two partials in the host's views, rendered when the file exists:

| Partial | Where | Locals |
|---|---|---|
| `harbor/reviews/_round_review.html.erb` | A round's page, inside the Review section, in place of Harbor's plain reading of the round's `review` | `round`, `doc` |
| `harbor/shared/_quality_guide.html.erb` | The top of the policy page: how the Quality pages fit together and how to use this one | `current` (`:reviews`), `steps`, `open` |

### What a host's review flow does

Until Harbor runs reviews, a host that reviews pull requests does this itself, with
Harbor's records:

1. Makes a `Harbor::ReviewRound` for the pull request's head commit, and decides which
   of `Harbor.review_rule_class.running.for_repo(repo)` apply (the risks' detectors, the
   checks that mitigate them).
2. Makes a `Harbor::ReviewCheckRun` per check, with the rule's `version_number` as
   `check_version` and the rule's `mode`, runs it as a tracked run (`run_id`), and ends
   it with `check_run.finish!(status:, summary:, outputs:, routed:)`.
3. Moves the round through its phases, fills in `gate`, `signoffs` and `review`, and
   sets `finished_at` when it is `published`, `cancelled` or `failed`.
4. Records `Harbor::ReviewFeedback` and `Harbor::ReviewEscape` as it learns what
   happened afterwards.

## Overview

Overview is the section's front page, at the section's own address (`/factory`,
`harbor.overview_path`; `/overview` where the section's pages sit at the root). It says
what is set up and how it has been going, **read from Harbor's records every time the page
is drawn**, so it can't fall behind them. Only the short note on each stage is written by
hand. A site with no code of its own sees:

- **At a glance**: one number each for runs in the last 30 days (with how many failed and
  how many are under way), what they spent, agents switched on, workflows live,
  automations and runtimes on, the share of judged runs the scorers passed, proposals
  waiting for a person, and review rounds. Each links to its page; one whose page is
  switched off is left out.
- **What is set up**: one stage, "Work", holding all of it. *Who does it*: every declared
  task type with the agent routing would give it to, its model and effort, and whether
  that is its own assignment, its fallback's or its default agent. *What it runs*: every
  workflow with its mode, version and steps, and every automation with whether it is on
  and what starts it. *How long, what it costs*: per task type over the last 30 days, the
  median and 90th percentile time of the runs that ended ok, the median cost, and how
  many ran and failed (`Harbor::Overview::Timings`).
- **What changed**: the newest fifty changes to the configuration, with who made them
  where that is recorded, and a "This week" filter (`?changes=week`). The sources are
  workflow versions, agents, agent documents, shared context, task routing, model
  choices, stage notes and review rule versions (`Harbor::Overview::Changes.recent`,
  which a host's own code can read too).

### Stage notes

Each stage has a note, edited in place on the page (`/factory/notes/<stage>`,
`harbor.stage_note_path`): `Harbor::StageNote`, on the table `factory_notes`, one per
stage. Until one is written the stage shows its summary. Every save is handed to
`config.export` as `factory/notes/<stage>.md`, with the stage, the time and who saved it
on top. With `config.user_class` set a note records who saved it. The note is shown as
plain paragraphs unless the host says how markdown is drawn:

```ruby
c.markdown = ->(text) { MyMarkdown.render(text) }   # returns HTML that is safe to show
```

The same renderer draws the ways in and the steering rows below, which may then use
backticks and bold.

### What a host declares

All optional, in an initializer (`Harbor::Overview`):

```ruby
# The stages work moves through, in order. Declaring any replaces "Work".
Harbor::Overview.stage "triage", title: "Triage", summary: "A ticket is read and given to someone.",
  task_types: %w[ticket_triage], automations: %w[ticket-sweep], claims: %w[triage],
  starts_on: ->(trigger) { trigger["kind"] == "ticket" }

# More lines under a stage's "What it runs".
Harbor::Overview.part(:checks, "Checks") do |stage, snapshot|
  stage.key == "review" ? [ Harbor::Overview::Item.new(label: "Spelling", mode: "live", url: "/checks/1", detail: "every change") ] : []
end

# How work arrives, and what a person can do about it.
Harbor::Overview.way_in "desk", title: "The help desk", body: "A ticket opened there.", stage: "triage", task_type: "ticket_triage"
Harbor::Overview.steer "hold", want: "Pause it", action: "add the `hold` label", result: "work stops", stage: "triage"

# Another source for "What changed", or one of Harbor's replaced by its name.
Harbor::Overview.change_source(:prices, "Price list") do |since:, limit:|
  PriceChange.recent(since:, limit:).map { |c| Harbor::Overview::Change.new(at: c.created_at, source: :prices, title: c.name, detail: c.summary, who: c.author, url: c.path) }
end

# Another number in "At a glance": the block is given the time it looks back to.
Harbor::Overview.tile(:tickets, label: "Tickets", after: :runs) { |since| { value: Ticket.open.count, note: "open", url: "/tickets" } }

# A section of the host's own, and one of Harbor's left out.
Harbor::Overview.section :costs, partial: "overview/costs", after: :lifecycle
Harbor::Overview.hide_section :summary
```

- **`stage`**: a stage holds the task types it names; the automations it names by key;
  the workflows that claim one of its `claims` (see Workflows, `register_claim`); the
  workflows and automations one of whose triggers its `starts_on` says yes to; and the
  workflows whose first agent step does one of its task types (`"agent": "task:<type>"`).
  `starts_on` is called with a trigger as a Hash: a workflow's trigger from its
  definition, or an automation's `trigger_data`, which is `[{ "kind" => trigger_kind }]`
  unless the host's automation class says more. A workflow or an automation no stage
  holds is listed under "Also running", so nothing live is left off the page. Declaring a
  stage again replaces it where it is.
- **`part`**: the block is called for every stage with the stage and the page's
  `Harbor::Overview::Snapshot`, and returns `Harbor::Overview::Item`s (`label`, and
  optionally `detail`, `mode` and `url`). Each is a line under "What it runs", after the
  workflows and automations, named by the part's title in the singular.
- **`way_in`** and **`steer`**: the "Ways in" and "How to steer" sections, which appear
  once there is something in them. A steering row also shows on its stage, under "Where
  people come in". A way in with a `task_type` says who that task goes to.
- **`change_source`**: the block is given `since:` (nil for "everything recent") and
  `limit:`, and returns `Harbor::Overview::Change`s.
- **`tile`**: `after:` names one of Harbor's tiles (`:runs`, `:spend`, `:agents`,
  `:workflows`, `:automations`, `:runtimes`, `:scorers`, `:proposals`, `:reviews`) or
  another of the host's; without it the tile goes last.
- **`section`**: Harbor's sections are `summary`, `ways_in`, `lifecycle`, `steering` and
  `changes`. The partial is rendered by Harbor's controller with `snapshot` and `stages`.

Two things are the host's classes' to say. `Harbor::Agent.edited_here` is the scope of
agents whose latest change was made on their page (every agent, unless a host that also
imports agents leaves those out in its subclass), which is what "What changed" lists.
`Harbor::Agent#effort_label` is the effort shown beside an agent's model (the first
choice of its model alias).

Two partials in the host's `app/views/harbor/overview/`:

| Partial | Where | Locals |
|---|---|---|
| `_intro.html.erb` | **Replaces** Harbor's heading and the paragraph under it. It may name the page too (`content_for :title`); Harbor names it "Overview" when it doesn't | none |
| `_note_form_hint.html.erb` | Beside the buttons of a stage note's form: what else a save does | none |

## Velocity

Velocity (`/factory/velocity`, `harbor.velocity_path`) is how much work ran over a
range, how it ended and what it cost. The range is one of the last 7, 30 or 90 days, 12
weeks (which the page opens on) or 6 months (`?range=30d`), and the tab is `?tab=`. A
site with no code of its own has three tabs, each read from Harbor's records:

- **Runs** (`Harbor::Velocity::Runs`): how many runs, how many ended ok and failed (an
  error or a timeout) with the failure rate, and the median time of the ones that ended
  ok; runs per week; each agent's runs and how they ended; runs by task type (top-level
  runs, so a delegated run isn't counted beside its parent); and runs by runtime.
- **Spending** (`Harbor::Velocity::Spending`): the total, how many runs had a cost and
  the mean per run; spend per week; spend by agent; spend by model. Costs are the
  actuals each run reported. A parent's total includes the runs it delegated, so only
  top-level runs are summed, plus the scorers' judge runs, which are billed on their own.
- **Scorers** (`Harbor::Velocity::Scoring`): how many judge runs there were and what
  they cost, and for each scorer its pass rate, its verdicts by label, its pass rate by
  week and its judge errors.

### What a host adds

```ruby
# config/initializers/harbor.rb
Harbor::Velocity.tab "tickets", label: "Tickets", partial: "velocity/tickets", before: "runs"
Harbor::Velocity.remove_tab "runs"
Harbor::Velocity.tile("spending", :per_ticket, label: "Per ticket", note: "median", after: :runs) do |period|
  "$%.2f" % Ticket.median_cost(period.range)
end
```

- **`tab`**: a tab of the host's own, before or after one of Harbor's (`runs`,
  `spending`, `scorers`) or last. Its partial is rendered by Harbor's controller with
  `period` (`Harbor::Velocity::Period`: `since`, `now`, `range`). The page opens on the
  first tab. `remove_tab` takes one of Harbor's away, for a host whose own tab says the
  same thing its way.
- **`tile`**: a number in the row at the top of a tab, after the tile it names
  (`after:`) or last. The block is given the period and returns what the tile shows.
  Harbor's tiles are `:runs`, `:ok`, `:failed` and `:median` on Runs; `:spend`, `:runs`
  and `:per_run` on Spending; `:judgements`, `:judge_spend` and `:scorers` on Scorers.
- **`period.fetch(:key) { … }`** keeps something built once per page, for a host whose
  tile and cards read the same figures.

Partials in the host's `app/views/harbor/velocity/`:

| Partial | Where | Locals |
|---|---|---|
| `_intro.html.erb` | **Replaces** Harbor's heading and the paragraph under it. It may name the page too (`content_for :title`) | none |
| `_spending_cards.html.erb` | The Spending tab's grid of cards, ahead of Harbor's: spend by whatever the host's work is about | `period` |
| `_runs_cards.html.erb` | The Runs tab's grid of cards, after Harbor's | `period` |

A host's own tab can show Harbor's cards: `harbor/velocity/runs_by_agent` (local
`by_agent`, `Harbor::Velocity::Runs#by_agent`) and `harbor/velocity/tiles` (local
`tiles`).

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

Overview is the page at the path itself (`/factory`). With the pages at the
root it is at `/overview`, because the root is the host's.

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
   a browser, because getting it wrong destroys data or runs a command: which
   databases are backed up and what may be restored over what (see Databases),
   and the recipes whose scripts start a machine for a run (see A machine for
   each run). It names the ENV keys that hold the secrets.
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
What Conductor Cloud takes (`conductor_cloud_user_agent`, `conductor_cloud_models`) is
under Conductor Cloud.
What the Agents pages take (`agent_params`, `agent_edited`, `task_assignment_class`) is
under Agents pages.
What automations take (`automation_class`, `automation_params`, `automation_edited`,
`automation_agent_run`, and what a host declares with `Harbor::Automations`) is under
Automations.
What workflows take (`workflow_class`, `workflow_run_class`, `user_class` and the
`workflow_*` hooks) is under Workflows.
What scoring and proposals take (`scorer_judge`, `scorer_judge_wait`, `proposal_drafter`,
`site_name`, `scorer_class`, `proposal_class`) is under Scorers and Proposals.
What Review policy takes (`review_rule_class`, `review_rule_version_class`,
`review_document_schema`, `review_pull_request_url`, `review_rule_preview`, `review_cost`,
and what a host declares with `Harbor::Reviews`) is under Review policy.
What Overview and Velocity take (`markdown`, and what a host declares with
`Harbor::Overview` and `Harbor::Velocity`) is under Overview and Velocity.

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
