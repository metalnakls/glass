# glasstoo Boundary

The old Glass UI experiments were intentionally not copied forward as the frontend foundation.

Carried forward:

- Transmission RPC models and client behavior
- profile and credential persistence
- backend refresh/cache/action behavior
- import parsing and source-file cleanup semantics
- product requirements from the native Glass work

Not carried forward:

- old `GlassRootView`
- old torrent row/list layout
- fake chrome experiments
- fake toolbar/header views
- layout-owned AppKit representables
- dirty `/Users/wsb/trans` frontend churn

The fresh app keeps the feature stack but rebuilds placement through native SwiftUI surfaces.
