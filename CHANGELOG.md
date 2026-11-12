# Changelog

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
