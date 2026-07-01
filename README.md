# Matrix Lightning Widget

Docker Compose stack: Bitcoin regtest, Core Lightning (two nodes with a channel), Synapse, Element Web, and an nginx gateway. All on port 80, no HTTPS.

## Requirements

- Docker Compose v2
- Apple Silicon (M-series) or amd64
- `/etc/hosts` entry: `127.0.0.1 citadel.test`

## Quick start

```bash
make up
```

Opens Element at http://citadel.test. Login: `admin` / `citadel`.

## What it does

- Spins up two CLN nodes (node-a, node-b) with a 500k sat channel on regtest
- Registers a Matrix admin user and Synapse homeserver
- Serves a Lightning wallet widget at http://citadel.test/widget.html
- Proxies everything through a single nginx gateway on port 80

## Adding the widget to a room

The widget lives at http://citadel.test/widget.html. To pin it in an Element room:

1. Open a room (non-encrypted recommended, but encrypted works too)
2. Type: `/addwidget http://citadel.test/widget.html Lightning`
3. Press Enter

The widget appears in the room's top bar, or in the Widgets section of the room info panel. To open it, click the expand/pin icon next to "Custom" in the Widgets section.

The "Add widgets, bridges & bots" button in the room settings does not work — it requires a Dimension integration manager that isn't running here. Use `/addwidget` instead.

## Commands

| Command | What it does |
|---------|-------------|
| `make up` | Build and start everything |
| `make down` | Stop everything |
| `make status` | Show container health + channel state |
| `make shell` | Open lightning-cli for node-a |
| `make clean` | Wipe all data and restart fresh |

## Tests

```bash
bash tests/test_all.sh
```

Runs 33 tests covering infrastructure, APIs, widget content, security headers, edge cases, and a full keysend payment flow.
