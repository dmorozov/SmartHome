# custom_components — the Hub's extensions/fixes slot

This directory is volume-mounted into the Home Assistant container at
`/config/custom_components` (see `hub/compose.yaml`). Any custom integration
placed here is picked up by HA on restart — no image rebuild, no fork of the
Hub. This is the designated slot for our own device extensions and fixes
(e.g. patching a broken cloud integration, or integrating a device HA core
does not cover).

## Why a volume mount and not a custom Docker image

Per ADR-0002 (`docs/adr/0002-home-assistant-headless-hub.md`), the Hub is a
black-box appliance: pinned versions, internals never modified. A custom
`Dockerfile` layered on the HA image would couple every HA upgrade to an image
rebuild and invite drift. Custom *components*, however, are plain Python
packages loaded from `/config` — a bind mount delivers them with zero image
changes. We deliberately do NOT build a custom image until a component needs a
**system-level dependency** (an apt package, a compiled library) that a
`/config` mount cannot provide. If that day comes, add a `build:` section to
`compose.yaml` and record the decision in a new ADR.

## Anatomy of a custom component

Each integration is a directory named after its **domain**, containing at
minimum a `manifest.json` (domain, name, version, requirements) and an
`__init__.py`:

```
custom_components/
└── my_device/
    ├── manifest.json
    ├── __init__.py
    └── sensor.py        # one module per platform the integration provides
```

`manifest.json` is mandatory and its `version` key is required for custom
integrations. Python package requirements are declared there and installed by
HA at load time (into the container — another reason plain-Python components
need no custom image).

Full developer documentation: <https://developers.home-assistant.io/docs/creating_component_index/>
