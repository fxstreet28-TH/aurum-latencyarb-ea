# AURUM LatencyArb V4.4b — Event Contract

This is the JSON contract the EA must send to the dashboard. The MQL5 side will
be implemented against **this file** — every field here maps 1:1 to a column in
`supabase/schema.sql`. Keep them in sync.

## Transport

- **Endpoint:** `POST https://<your-app>.vercel.app/api/events`
- **Auth:** `Authorization: Bearer <INGEST_API_KEY>` — this authenticates the
  sender. It is **separate** from `deployment_id`, which only *labels* which
  pair the event came from.
- **Content-Type:** `application/json`
- **Body:** either a single event object, or a batch: `{ "events": [ ... ] }`
- **Response:** `{ "ok": true, "ingested": N, "failed": M }`. A single bad event
  never fails the batch — it is counted in `failed` (with an `errors[]` array)
  and the rest still land.

## Common envelope (every event)

| field | type | required | notes |
|---|---|---|---|
| `deployment_id` | string | ✅ | pair token from the EA input. Same for A and B. |
| `ea_version` | string | ✅ | e.g. `"4.4b"` |
| `role` | string | ✅ | `A1` \| `A2` \| `A3` \| `B` |
| `broker` | string | ✅ | broker/company name for this terminal |
| `symbol` | string | ✅ | symbol on this terminal (A and B may differ, e.g. `XAUUSD` vs `XAUUSD.c`) |
| `event_type` | string | ✅ | `heartbeat` \| `cycle` \| anything else (raw-logged) |
| `login` | number | ⬜ | MT5 account login for this terminal (used by heartbeat) |
| `vps_host` | string | ⬜ | e.g. `"192.248.162.147"` (used by heartbeat) |
| `vps_port` | number | ⬜ | e.g. `12308` (used by heartbeat) |
| `payload` | object | ⬜ | event-specific data (see below) |

Every event — whatever its type — is written verbatim to `ea_events`.

## `heartbeat` — every 30s, from BOTH A and B

Upserts the `deployments` row. If `role` starts with `A`, the `a_*` columns +
`a_last_seen` are updated; if it starts with `B`, the `b_*` columns +
`b_last_seen`. `vps_host` / `vps_port` / `ea_version` are written on every
heartbeat. The other side's columns are left untouched.

```jsonc
{
  "deployment_id": "ld4-01",
  "ea_version": "4.4b",
  "role": "A1",                    // A1 | A2 | A3 | B
  "broker": "Tickmill Ltd",
  "login": 55921405,
  "symbol": "XAUUSD",
  "vps_host": "192.248.162.147",
  "vps_port": 12308,
  "event_type": "heartbeat",
  "payload": { "ticks": 18422, "spread_pts": 21.0 }
}
```

`payload` on a heartbeat is free-form (stored in `ea_events.payload`); nothing
in it is required.

## `cycle` — on cycle close, from B ONLY

Upserts a `cycles` row keyed by `(deployment_id, cycle_uid)`. Re-sending the
same `cycle_uid` updates the existing row instead of creating a duplicate — so
the EA may safely **retry** a failed send.

The endpoint guarantees the `deployments` row exists first (FK), creating an
empty one from `deployment_id` if no heartbeat has arrived yet.

```jsonc
{
  "deployment_id": "ld4-01",
  "ea_version": "4.4b",
  "role": "B",
  "broker": "GOC Prime Limited",
  "symbol": "XAUUSD.c",
  "event_type": "cycle",
  "payload": {
    "cycle_uid": "ld4-01-1737891234567",
    "direction": "BUY",
    "t_signal": 84719234, "t_leg1_fill": 84719412,
    "t_hedge_fill": 84720890, "t_close": 84722104,
    "opened_at": "2026-07-27T09:14:32.000Z",
    "cycle_duration_ms": 2870,
    "ab_lag_ms": 178, "signal_to_fill_ms": 178,
    "a_delta_pts": 62.0, "a_brokers_agreed": 1,
    "a_price_at_signal": 4055.12, "b_price_at_signal": 4054.50,
    "b_spread_pts_at_signal": 44.0,
    "hedge_opened": true, "hedge_trigger_pts_used": 54.0,
    "leg1_ticket": 123456, "leg1_expected_price": 4054.72,
    "leg1_actual_price": 4054.79, "leg1_slippage_pts": 7.0,
    "hedge_ticket": 123457, "hedge_expected_price": 4055.26,
    "hedge_actual_price": 4055.31, "hedge_slippage_pts": 5.0,
    "locked_profit_pts": 11.0,
    "exit_reason": "A_PEAK", "final_state": "WINNER_CLOSED",
    "gross_pts": 94.0, "net_pts": 88.0, "net_money": 0.88,
    "is_win": true,
    "session": "LONDON", "b_atr_m1_pts": 132.0
  }
}
```

### `cycle` payload fields

Required (row is rejected without them):

| field | type | column |
|---|---|---|
| `cycle_uid` | string | `cycle_uid` — unique per deployment; idempotency key |
| `opened_at` | ISO 8601 string | `opened_at` |
| `direction` | string `BUY`\|`SELL` | `direction` (first leg) |

Timing (ms from `GetTickCount64()` on the VPS — comparable across terminals):

| field | column |
|---|---|
| `t_signal` | `t_signal` |
| `t_leg1_fill` | `t_leg1_fill` |
| `t_hedge_fill` | `t_hedge_fill` |
| `t_close` | `t_close` |
| `cycle_duration_ms` | `cycle_duration_ms` |

Latency (the dashboard's core question):

| field | column | notes |
|---|---|---|
| `ab_lag_ms` | `ab_lag_ms` | **may be `null`** if not measured. Send `null`, never `0`. |
| `signal_to_fill_ms` | `signal_to_fill_ms` | |

Signal context:

| field | column |
|---|---|
| `a_delta_pts` | `a_delta_pts` |
| `a_brokers_agreed` | `a_brokers_agreed` |
| `a_price_at_signal` | `a_price_at_signal` |
| `b_price_at_signal` | `b_price_at_signal` |
| `b_spread_pts_at_signal` | `b_spread_pts_at_signal` |

Delayed hedge & execution:

| field | column |
|---|---|
| `hedge_opened` | `hedge_opened` (boolean, default `false`) |
| `hedge_trigger_pts_used` | `hedge_trigger_pts_used` |
| `leg1_ticket` | `leg1_ticket` |
| `leg1_expected_price` | `leg1_expected_price` |
| `leg1_actual_price` | `leg1_actual_price` |
| `leg1_slippage_pts` | `leg1_slippage_pts` |
| `hedge_ticket` | `hedge_ticket` |
| `hedge_expected_price` | `hedge_expected_price` |
| `hedge_actual_price` | `hedge_actual_price` |
| `hedge_slippage_pts` | `hedge_slippage_pts` |
| `locked_profit_pts` | `locked_profit_pts` |

Outcome:

| field | column | allowed values |
|---|---|---|
| `exit_reason` | `exit_reason` | `A_PEAK` \| `A_TROUGH` \| `TIMEOUT` \| `EMERGENCY_SL` \| `INITIAL_SL` |
| `final_state` | `final_state` | `SINGLE_LEG` \| `HEDGE_OPEN` \| `WINNER_CLOSED` |
| `gross_pts` | `gross_pts` | |
| `net_pts` | `net_pts` | |
| `net_money` | `net_money` | account currency |
| `is_win` | `is_win` | boolean; may be `null` if undecided |

Context:

| field | column | allowed values |
|---|---|---|
| `session` | `session` | `ASIA` \| `LONDON` \| `NY` \| `LONDON_NY_OVERLAP` |
| `b_atr_m1_pts` | `b_atr_m1_pts` | |

## Null handling

Any numeric field that the EA could not measure should be sent as JSON `null`
(or simply omitted) — **never** as `0`. `0` is a real measured value and would
corrupt latency/slippage statistics. This matters most for `ab_lag_ms`.

## Other event types

Any `event_type` other than `heartbeat` / `cycle` (e.g. `error`, `signal`,
`info`) is accepted and stored raw in `ea_events` with its `payload`. It does
not touch `deployments` or `cycles`. Use these for debugging breadcrumbs.
