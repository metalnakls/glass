# Sticky-header runtime trace

The trace is disabled by default. The Glass-specific diagnostic key uses the
shared preferences domain because macOS can block external writes to the app’s
sandbox container. It does not change any other app’s behavior. Enable or disable it while Glass is running:

```sh
defaults write NSGlobalDomain GlassDiagnostics.traceHeaders -bool YES
defaults delete NSGlobalDomain GlassDiagnostics.traceHeaders
```

After enabling, reproduce the short-scroll header behavior manually, then read
the recent trace:

```sh
log show --last 10m --style compact --predicate 'subsystem == "tsmc.glass" AND category == "sticky-headers"'
```

Each controller has a short random identifier to separate windows. Scroll
geometry records are limited to ten per second; section-state changes and live
scroll lifecycle notifications are recorded separately. Records include title
indices and frames, scroll/clip/document geometry, the registered safe-area bar
frame and insets, and the empty custom-effect state. They do not contain title
text, torrent names, paths, bookmarks, or credentials. The trace labels native
blur visibility `unknown`: it records ownership-adjacent geometry and the
empty-effect alpha, not rendered native blur pixels. Trace entries use the
unified log `notice` level, so the query does not need `--info`. Disable tracing
after reproducing the issue. The new trace code must first be installed; after
installation, manually reopen Glass once to load that build. Then the preference
can be enabled and disabled without relaunching.
