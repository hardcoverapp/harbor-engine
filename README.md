# Harbor

A software factory for Rails apps: a mountable engine that runs agent work.
Workflows whose steps are runs, placed on runtimes through workspaces, executed
by agents with routed models, judged by scorers, improved through proposals,
and triggered by webhooks and schedules.

Harbor is being extracted from Hardcover's internal app, one area at a time.
**It is early.** Today the engine holds the foundation: the section menu, the
settings system and the Settings page. The rest arrives as it is cut free of
the app it came from.

## Installing

Harbor is not published as a gem yet. Add it from this repository:

```ruby
# Gemfile
gem "harbor", github: "hardcoverapp/harbor-engine"
```

Mount it last in the host's routes, so the host's own routes win:

```ruby
# config/routes.rb
mount Harbor::Engine => "/", as: :harbor
```

Its migrations run with the host's (`bin/rails db:migrate`); nothing is copied.

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
  # The controller Harbor's pages inherit from: it brings the host's login
  # check, layout and current user. This is the default.
  c.parent_controller = "ApplicationController"

  # How to name the person who changed a setting.
  c.user_label = ->(user) { user.name }

  # Called with (relative path, text) when saved configuration changes, to
  # keep a copy outside the database. Optional.
  c.export = ->(path, body) { File.write(Rails.root.join("storage", path), body) }

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

### The menu

`Harbor.nav` is the one list behind the host's menu and the tabs above each
page. In the host's layout:

```erb
<% harbor_nav_links.each do |link| %>
  <%= link_to link.label, link.path, class: ("current" if link.active) %>
<% end %>
```

### What the host has to provide, for now

Harbor's pages render inside the host's layout and use the host's stylesheet.
Until Harbor ships its own styles, its views expect these class names to mean
something: `card`, `pill`, `meta`, `display`, `field`, `btn-quiet`, and the
colour utilities `bg-pale-green`, `text-ink-green`, `bg-pale-red`,
`text-ink-red`, `text-soft`, `text-ink`, `border-hairline`. Several menu
entries also point at routes that still live in the host (`runs_path`,
`agents_path`, …); see `Harbor::Nav::DEFAULTS`.

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

## Licence

MIT. See `LICENSE`.
