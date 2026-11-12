# Changelog

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
