# Device API — proposed contract with lal.gg / Directus

**Status: PROPOSAL.** Nothing here exists on the server yet. This document is the input
for the "Beamer devices" issue in `lockandloadch/lockandload.ch-3.0`, following that
repo's own rules (issue + plan comment first, `directus-schema/README.md` before any
collection or permission). The agent in this repo already speaks this contract, so the
server side can be built and tested against a real box.

The design follows the pattern the rewrite already uses for other modules: tenant-scoped
collection, `lalgg-tenant-guard` field guards, a dedicated low-privilege policy, and the
app (not the device) is where privileged actions happen.

## 1. Principles

- **Outbound only.** The device never listens on the network. It polls (or, once
  `WEBSOCKETS_ENABLED` is on, subscribes to) its own row.
- **Enrollment is authorised by a human with 2FA, then the human's session is gone.**
  An Org Admin (or a lighter "Technician" role, see §6) claims a pairing code in the web
  app. The device receives its *own* identity: a Directus user with the "Beamer Device"
  role and a static token that can do exactly what §4 lists. Nothing of the admin stays
  on the box.
- **A device token is low-value and revocable.** Revoking = deleting the device user (or
  its token) from the Beamer-Clients tab. The box falls back to the pairing screen.
- **Same page everywhere.** `/beamer/device` is the same Vue route on a laptop and on an
  appliance. The page asks `http://127.0.0.1:8484/info`; if that answers, it is on a
  managed box and shows the pairing code / machine controls. If not, it shows up in the
  admin panel as "web browser" with machine controls greyed out.

## 2. Collection `beamer_devices`

Tenant-scoped, like `beamer_slide_templates`. One row per physical box (or browser
session, see `kind`).

| Field | Type | Written by | Notes |
|---|---|---|---|
| `id` | uuid | – | |
| `tenant` | M2O `tenants` | admin | required; tenant guard |
| `event` | M2O `events` | admin | optional; must belong to `tenant` |
| `assigned_playlist` | M2O `beamer_playlists` | admin | must belong to `event` |
| `name` | string | admin | "Bühne links", "Empfang" |
| `kind` | string | app | `appliance` \| `browser` |
| `status` | string | app | `pending` (claimed, not yet enrolled) \| `active` \| `revoked` |
| `fingerprint` | string, unique | agent (via claim) | 16 hex from the agent |
| `pairing_code` | string | agent (via claim) | 6 chars, only meaningful while `pending` |
| `device_user` | M2O `directus_users` | app (server side) | the device's own login; deleting it revokes the box |
| `manage_url` | string | admin | optional override pushed to the box |
| `hostname` | string | device | heartbeat |
| `ip_address` | string | device | heartbeat |
| `agent_version` | string | device | heartbeat |
| `hardware` | json | device | heartbeat: vendor, product, serial, cpu, memory, displays, ips |
| `uptime_s` | integer | device | heartbeat |
| `temperature_c` | float | device | heartbeat |
| `last_seen` | timestamp | device | heartbeat; "online" = `now − last_seen < 3 × POLL_SECONDS` |
| `pending_command` | string | admin → device clears | `reboot` \| `restart-browser` \| `update` \| `console` |
| `last_command` | string | device | |
| `last_command_result` | text | device | |
| `last_command_at` | timestamp | device | |
| `date_created`, `user_created`, … | | | standard |

Scheduling ("show playlist X from 22:00") is a later addition and belongs on
`beamer_playlists`/a schedule collection, not on the device.

## 3. Enrollment flow

```
box                         browser page (same box)            lal.gg app (admin)          Directus
 |  boot, no token           |                                   |                          |
 |<---- GET /info ---------- |                                   |                          |
 | {code, secret, fp, hw}    |                                   |                          |
 |                           | shows "Code 4F7K"                 |                          |
 |                           |                                   | admin enters 4F7K,       |
 |                           |                                   | picks event + playlist   |
 |                           |                                   |---- POST /beamer/claim -->|  (Flow or extension endpoint,
 |                           |                                   |     {code, tenant,...}   |   runs as the admin: creates
 |                           |                                   |                          |   beamer_devices row status=pending)
 |                           |--- GET /beamer/pair?fp&secret -----------------------------> |  public endpoint; if a pending row
 |                           |    (polls every 5 s)                                          |  exists for fp: create device user +
 |                           |<-- {device_id, device_token, directus_url} ----------------- |  static token, status=active, return once
 |<--- POST /enroll ---------|                                                               |
 |  {secret, device_id, tok} |                                                               |
 | writes config, restarts   |                                                               |
 | heartbeat loop starts     |                                                               |
```

Why the *secret* exists: the pairing code is short and visible on a wall. The random
secret is only readable by the page running on the box (via localhost), so only that
page can finish enrollment and only that agent accepts the token. A photo of the screen
gets an attacker nothing without also being the process on the box.

Both `/beamer/claim` and `/beamer/pair` are small server-side pieces (a Directus Flow
with a webhook trigger, or a custom endpoint extension in `directus-extensions/`).
`/beamer/pair` must be rate-limited and must delete the pairing state after one success.

## 4. Role and policy "Beamer Device"

One policy, `app_access: false`, `admin_access: false`, `enforce_tfa: false`:

| Collection | Action | Filter / fields |
|---|---|---|
| `beamer_devices` | read | `device_user = $CURRENT_USER`; all fields |
| `beamer_devices` | update | same filter; **only** `hostname, ip_address, agent_version, hardware, uptime_s, temperature_c, last_seen, pending_command (to null), last_command, last_command_result, last_command_at` |
| `beamer_playlists`, `beamer_playlist_items`, `beamer_slide_templates`, `beamer_slide_template_images`, `directus_files` (assets) | read | what the Public policy already allows today (the player is login-less), nothing more |

A device therefore cannot see other devices, cannot change its own assignment, and
cannot escalate. The app never needs the device token; the page only ever *hands it to
the agent* during enrollment.

## 5. Agent ↔ Directus traffic (as implemented in `agent/lalgg_agent.py`)

Every `POLL_SECONDS` (default 30):

```
PATCH /items/beamer_devices/{DEVICE_ID}?fields=pending_command,assigned_playlist,manage_url
Authorization: Bearer <device token>
{ "last_seen": "...", "agent_version": "...", "hostname": "...", "hardware": {...},
  "ip_address": "...", "uptime_s": 12345, "temperature_c": 47.2 }
```

If the response carries `pending_command`, the agent executes it and writes back

```
PATCH /items/beamer_devices/{DEVICE_ID}
{ "pending_command": null, "last_command": "reboot", "last_command_result": "rebooting",
  "last_command_at": "..." }
```

`401/403` → token revoked → agent idles and the page (which also lost its playlist) shows
the pairing screen again. Network errors back off exponentially to 5 minutes.

The **player** does not go through the agent: the page reads `assigned_playlist` from the
device row (public read via the pairing endpoint, or the device token relayed by the
agent) and then behaves like today's `/beamer/:playlistId`.

## 6. UI in lal.gg (for the issue)

- **Org → Beamer-Clients**: all devices of the tenant, online dot, name, event, playlist,
  last seen, hardware summary (vendor/product/serial), buttons: Reboot · Restart browser
  · Update · Console · Revoke. "Claim device" input for a pairing code.
- **Event → Beamer tab**: the same list filtered to this event, plus "assign playlist".
- Browser sessions (`kind = browser`) appear too, with the machine controls disabled.
- Optional later: a "Technician" tenant role (`tenant_members.tenant_role`) allowed to
  claim/reboot devices but not to edit content.

## 7. Open questions for Fabrizio

1. Flow vs. custom endpoint extension for `/beamer/claim` and `/beamer/pair`.
2. Whether a device should be a `directus_users` row (simplest, uses static tokens and
   existing policy machinery) or a separate token table with a custom auth hook.
3. `WEBSOCKETS_ENABLED` on the instance so both the player and the agent can subscribe
   instead of polling.
4. Naming: `beamer_devices` vs. `beamer_clients` (the UI says "Beamer-Clients").
