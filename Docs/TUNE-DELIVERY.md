# Tune delivery

Tune snapshots include every AppearanceStorage control declared by the Tune view.
The defaults registry supplies supported keys and types for saving and client-side
validation. The inspector search switch and Add title insets were previously absent
from that registry, so saving silently dropped them. The saved snapshot now includes
`GlassInspector.permanentSearch: false`; all previously saved entries are preserved.

Manual Check for Updates actions use GlassUpdateAvailability, which checks the app
and forces a Tune refresh. Automatic launch/activation checks retain their throttle.
Cached Tune data remains usable offline. Unknown or unsupported values continue to
be skipped individually, without discarding the complete saved snapshot.

The inspector's existing completed-download layout still expands search when there
is no progress control. This change fixes the saved permanent-search setting and its
delivery; it does not replace that established layout policy.

The publicly released 8.2 client does not recognize the omitted search setting in its
Tune schema. It needs an app update containing the registry correction; publishing
only a new Tune file cannot add support to that already-built client. Use the project
release and Tune publication scripts when publication is authorized.
