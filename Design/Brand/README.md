# Nettwork brand assets

<!-- markdownlint-disable MD013 -->

## Mark

The Nettwork mark is a continuous cable-shaped `N` joining four endpoints. It
represents traceable physical connections without depicting a particular
vendor, protocol, rack, or building.

The production master is `NettworkIconMaster.png`. It is an opaque 1024×1024
PNG with full-bleed artwork and no platform-specific corner mask. Apple applies
the appropriate icon mask at runtime.

Do not add text, a border, a Wi-Fi symbol, a globe, small rack details, or
credentials and network identifiers to the mark. Do not round the master
artwork before placing it in the asset catalog.

## Palette

| Asset | Light | Dark | Purpose |
| --- | --- | --- | --- |
| `AccentColor` | `#007178` | `#18E7E0` | Global controls and primary actions |
| `BrandNavy` | `#07163F` | `#0B1E4B` | Brand field and high-contrast surfaces |
| `BrandTeal` | `#007178` | `#18E7E0` | Brand mark and selected connectivity |
| `LaunchBackground` | `#F7F9FC` | `#07163F` | Adaptive iOS launch surface |
| `Surface` | `#FFFFFF` | `#112149` | Branded cards where system material is unsuitable |
| `StatusReady` | `#1E7A46` | `#46C884` | Confirmed and synchronized state |
| `StatusPending` | `#0063B8` | `#68B5FF` | Loading and synchronization state |
| `StatusOffline` | `#A94608` | `#FFB277` | Offline and degraded state |
| `StatusConflict` | `#B02A37` | `#FF7B86` | Rejected or conflicting state |
| `StatusReserved` | `#6A45A5` | `#C89BFF` | Reserved resources and planned work |

Status is never communicated by color alone. Pair every status color with text,
an icon, or both.

## Catalog

`NettworkApp/Resources/Assets.xcassets` is shared by the iPhone/iPad and native macOS
targets. `AppIcon.appiconset` contains every required iPhone, iPad, Mac, and App
Store rendition. `NettworkMark.imageset` is the reusable in-app square mark.
The named color sets supply light and dark variants.

Regenerate deterministic PNG renditions after replacing the master:

```sh
bash scripts/generate-app-icons.sh
```

Validate catalog references, JSON, dimensions, opacity, and colors:

```sh
bash scripts/validate-assets.sh
```

Full compilation through `actool`, simulator appearance, system masking, and
App Store validation still require the generated Xcode project and full Xcode.
