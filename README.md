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

Harbor's JavaScript is two small Stimulus controllers (the side nav's collapse,
and a log that follows its newest line). On `importmap-rails` with the usual
`eagerLoadControllersFrom("controllers", application)` there is nothing to do:
Harbor pins them under `controllers/harbor/`.

The Settings page itself still expects a few class names to mean something in
the host's stylesheet: `card`, `pill`, `meta`, `display`, `field`, `btn-quiet`,
and the colour utilities `bg-pale-green`, `text-ink-green`, `bg-pale-red`,
`text-ink-red`, `text-soft`, `text-ink`, `border-hairline`. Without them it
works and looks plain.

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

## Runtimes and workspaces

A `Harbor::Runtime` is a place work can run, with a limit on how much at once.
The code that drives one is its backend, a subclass of
`Harbor::Runtimes::Backend` registered by name:

```ruby
# config/initializers/harbor.rb
Harbor::Runtimes.register "laptop", "Backends::Laptop"
```

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

Harbor's own backend is `orca`: a runtime is an [Orca](https://github.com/stablyai/orca)
server, the one beside Harbor or one paired with its machine
(`orca environment add`). Its config says where:

```json
{ "repo": "name:app", "environment": "sam-laptop", "setup": "skip" }
```

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
in front of it. Those two routes have no login: each request carries a token
good for one run, which can append to that run's log and report its result and
nothing else. By default a reported exit status finishes the run as ok or
error; `c.run_reported = ->(run, exit_status:) { … }` takes that over.

The runner needs `sh`, `curl` and the `orca` command where Harbor runs. An Orca
server listens on every interface, so never give one a public address.

`c.sticky_runtime` sends follow-up work back to the runtime that holds its
workspace, and `c.runtime_class` / `c.workspace_profile_class` name a host's
subclasses.

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

Harbor backs up the databases a site declares and refreshes staging copies of
them, on the Databases page (`/databases`). Every backup and restore is a run.

- **Backups** come in three kinds per database. `full` is everything, for
  disaster recovery. `cleaned` is masked while it is read, so it is safe to hand
  to developers. `staging` is masked with a second set of rules, for a staging
  site that needs more kept than a laptop does. Each dump is a folder
  `<database>/<kind>/<dump id>/`, cataloged in `Harbor::DatabaseBackup` with its
  size and checksum.
- **Staging refreshes** replace a database's staging copy with a saved masked
  dump (staging, else cleaned). A full dump is never restored anywhere.
- MySQL databases get full backups only.

### What it needs

Nothing, until a database is declared: with none, the page says so and no tool
is run. Harbor never loads or looks for these when the app boots. They are
needed where the jobs run, when a backup or restore runs:

- [Greenmask](https://greenmask.io), which makes every PostgreSQL dump.
- `pg_dump`, `pg_restore` and `psql`, at least as new as the newest server.
- `mysqldump`, `mysql` and `gzip`, if a MySQL database is declared.
- The `aws-sdk-s3` gem in the host's Gemfile, if dumps are copied to a bucket.

### Declaring databases

Connection strings are secrets, so they stay in ENV. A declaration names the
ENV keys:

```ruby
# config/initializers/harbor.rb
Harbor::Databases.declare "shop",
  source_env: "SHOP_DATABASE_URL",            # what is backed up; point it at a read-only role
  staging_env: "SHOP_STAGING_DATABASE_URL",   # optional: what a staging refresh replaces
  variants_env: "SHOP_BACKUP_VARIANTS",       # optional: an ENV key listing the kinds to make ("full,cleaned")
  freshness: { "orders" => "created_at" }     # optional: tables whose newest row proves the source is live

Harbor::Databases.declare "app", own: true, owner: "Storefront"   # the app's own database
```

A `postgres://` URL is dumped with Greenmask, a `mysql://` one with
`mysqldump`. `own: true` is the database Rails is connected to: full backups
only, never a restore target. A database with `freshness:` tables is not backed
up once its newest row is older than the **Newest write allowed** setting,
because a source that stopped receiving writes is usually the wrong server.

A list that isn't known until it is asked for is declared in a block, run each
time the list is read: `Harbor::Databases.declare_each_time { |list| list.declare … }`.

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

Under **Databases** on the Settings page: **Staging restores** (off by
default), **Backups kept**, **Parallel dump jobs**, **Free space needed**,
**Newest write allowed**, **Oldest backup a refresh uses**, **Connection
timeout** and **Upload threads**.

### What a restore will not do

A restore drops every schema in its target first, so the target is checked
before anything is queued and again by the job:

- **Staging restores** must be switched on.
- The target must not be any declared database's source, the app's own
  `DATABASE_URL`, or any database in Rails's own configuration. Nothing
  overrides this.
- The target's database name or host must contain `staging`. A site whose
  disposable database is named otherwise sets an ENV key to `true` on the
  machine: `HARBOR_ALLOW_UNSAFE_RESTORE`, or the key named by
  `c.unsafe_restore_env`.
- Two databases may not share a staging target.
- Only a masked dump is restored, and only after its size and checksum match
  what was cataloged.

While a restore runs, the staging role is made read-only and its other
connections are closed (`c.staging_lock_role` names a role other than the one
in the URL; `c.restore_spared_applications` lists application names whose
connections are left alone).

### Starting operations

The jobs are tracked runs. `Harbor::DatabaseRestoreJob` restores one chosen
backup. Backing up and refreshing every staging database are jobs the host
writes on `Harbor::DbOperationJob`, because when they run is the host's
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
without this the page shows the databases and their backups and starts nothing:

```ruby
Harbor.configure do |c|
  jobs = { "db-backup" => "DatabaseBackupJob", "database-restore" => "Harbor::DatabaseRestoreJob", "staging-restore" => "StagingRefreshJob" }
  c.database_operation = lambda do |operation, user:, input:|
    run = Harbor.run_class.create!(loader: operation, trigger_source: "manual", input: input.merge(loader: operation))
    jobs.fetch(operation).constantize.perform_later(run.id)
    run
  end
  c.database_schedule = ->(operation) { MySchedule.next_run_at(operation) }   # optional: "Next: …" on the page
end
```

A host with a base job of its own for tracked work names it
(`c.tracked_job = "MyTrackedJob"`); the default is `Harbor::TrackedJob`.

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

Harbor is configured in three places, and a value goes in the first one it can:

1. **Settings in the app.** Everything that is data: switches, limits, and
   later repositories, identities and task types. Edited on the Settings page;
   a change takes effect at once, with no deploy or restart.
2. **The environment.** Secrets only.
3. **Ruby**, in a host initializer. Only what is code:

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
