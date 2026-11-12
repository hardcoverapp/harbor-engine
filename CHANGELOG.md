# Changelog

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
