# Zen sidebar metrics

Read from Zen's own CSS (`docs/reference/zen/`, cloned shallow, MPL-2.0,
gitignored). These are **measurements, not code** — nothing is copied, and Zen
is a Firefox fork so nothing could be. See `docs/ui-parity.md` for scope.

Source: `src/zen/tabs/zen-tabs/vertical-tabs.css`, `src/zen/spaces/zen-workspaces.css`.

| Token | Value | Applied to |
| --- | --- | --- |
| `--border-radius-medium` | **10px** (6 compact / 12 expanded) | row pill, essentials tile, space pill |
| `--tab-min-height` (regular) | **28px** | tab row height |
| `--tab-min-height` (essentials) | **44px** | essentials tile height |
| `--min-essentials-width-wrap` | `tab-min-height + 4` = **48px** | minimum essentials tile width |
| essentials grid | `repeat(auto-fit, minmax(max(23.7%, 48px), 1fr))` | **~4 per row**, reflowing to fewer as the sidebar narrows |
| `--tab-inline-padding` | **8px** | row leading/trailing inset |
| `--zen-toolbox-padding` | **5–6px** | sidebar outer padding |
| workspace strip height | **28px** | spaces bar |
| workspace strip gap | **3px** | between space pills |
| workspace indicator dot | **6px**, `border-radius: 50%` | current-space dot |

## Notes

Pane's 28pt row pitch was already correct — arrived at independently and
confirmed here.

The essentials grid is **auto-fit with a percentage minimum**, not a fixed
column count. Spec §5 says "4 per row"; Zen gets ~4 at a normal width and
reflows to 3 or 2 as the sidebar narrows. Pane now does the same, which is
strictly better than a hard 4 that squashes into pills. §5's "4 per row" is
satisfied at the default width.

`--border-radius-medium` varies with Zen's density setting. Pane has no density
setting (that would be theming, which is out of scope per `docs/ui-parity.md`),
so it takes the default 10.
