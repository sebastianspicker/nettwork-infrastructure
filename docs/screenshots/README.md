# Demo screenshots

These are unedited browser captures of the static mock-data demo in `site/`.
They do not show the native Apple apps or a live infrastructure connection.

| Image | View | Capture size |
| --- | --- | --- |
| `demo-trace.png` | Trace, timeline, and related work | 1600 × 1000 |
| `demo-overview.png` | Rack capacity and attention queue | 1600 × 1000 |
| `demo-physical.png` | Representative rack elevation | 1600 × 1000 |
| `demo-logical.png` | VLAN and addressing relationships | 1600 × 1000 |
| `demo-mobile.png` | Overview with stacked capacity cards | 390 × 1088 |

Captured on 14 September 2026 with Playwright 1.63.0 and its headless Chromium,
light color scheme, and device scale factor 1. Desktop images use a
1600 × 1000 viewport. The mobile image uses a 390 × 844 viewport with a
full-page capture.

To reproduce, run this command from the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory site
```

Open `http://127.0.0.1:8765/` in a browser with a fresh storage context and light
color scheme. Capture the initial Trace view, then select Overview, Physical,
and Logical for the other desktop views. For the mobile image, use a
390 × 844 viewport, select Overview, and capture the full page.

Capture checks confirmed the expected page title and view headings, no console
warnings or errors, working work-order ready/reopen controls, keyboard tab
navigation from Trace to History, and the mobile location menu. The narrow
Trace view uses a horizontally scrollable path. These checks cover the demo
only, not native app behavior, live data, or backend integration.
