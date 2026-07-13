# `/api/v1/stream` WebSocket payload schema

Versioned message schema for the real-time TSL landmark stream between the
Flutter client and the Golang backend. Single source of truth per `docs/AGENTS.md`;
breaking changes bump `schema_version` here before any code changes.

**Current version: 1**

Transport: WebSocket (WSS in production). All messages are UTF-8 JSON text
frames. Every message carries `schema_version` (integer) and `type` (string).
Unknown `type` values must be rejected with an `error` message, not ignored.

Authentication: the upgrade request must carry a valid JWT access token in
the `Authorization: Bearer <token>` header (or the `signmind_access` cookie);
the backend rejects the handshake with a 401 RFC 7807 problem before
upgrading. Tokens never appear in the URL or in message payloads, so the
message schema itself is auth-free.

The backend forwards landmark sequences to the Python AI service over gRPC
bidirectional streaming (`docs/api/tsl_inference.proto`). No HTTP fallback on
this path (root DOX rule).

---

## Client → Server

### `landmark_frame`

One extracted feature vector per captured frame.

```json
{
  "schema_version": 1,
  "type": "landmark_frame",
  "seq": 123,
  "timestamp_ms": 1720252800000,
  "features": [0.01, -0.42, "... 441 floats total ..."]
}
```

| Field | Type | Rules |
|---|---|---|
| `seq` | integer | Monotonically increasing per connection, starting at 0. |
| `timestamp_ms` | integer | Client capture time, Unix epoch milliseconds. |
| `features` | float array | Exactly 441 values, laid out per the root Feature Vector Spec (`Agents.md` → Feature Vector Spec): position (147) then velocity (147) then acceleration (147). Position block layout: `[Pose 21 | Left hand 63 | Right hand 63]`, body-normalized (shoulder-mid centered, shoulder-width scaled). Missing detections are zero-filled. |

Note: the inference service consumes only the position block (first 147 dims)
and recomputes velocity/acceleration **after** person-invariant hand
normalization, mirroring training (`Inference_backend/tsl_preprocess.py`). Client-computed
deltas are carried for schema conformance and diagnostics, never fed to the
model.

### `reset`

Clears the server-side sliding window (e.g. when the user restarts scanning).

```json
{ "schema_version": 1, "type": "reset" }
```

---

## Server → Client

### `ready`

Sent once immediately after the connection is accepted and the AI stream is up.

```json
{ "schema_version": 1, "type": "ready" }
```

### `prediction`

Emitted whenever the AI service produces a prediction (requires a full
30-frame window server-side; not one reply per frame).

```json
{
  "schema_version": 1,
  "type": "prediction",
  "seq": 123,
  "word": "สวัสดี",
  "confidence": 0.94,
  "is_idle": false,
  "is_uncertain": false,
  "top": [ { "label": "สวัสดี", "prob": 0.94 }, { "label": "ขอบคุณ", "prob": 0.03 } ],
  "inference_micros": 4200
}
```

| Field | Type | Rules |
|---|---|---|
| `seq` | integer | `seq` of the latest `landmark_frame` included in the window. |
| `word` | string | Top-1 class label from `Inference_backend/TSL_Output/label_map.json`, or empty when `is_uncertain`. |
| `confidence` | float | Top-1 softmax probability, 0.0–1.0. |
| `is_idle` | bool | Idle/no-hands bypass fired (no model invocation). |
| `is_uncertain` | bool | Top-1 below the trained confidence threshold (`preprocess_config.json`); treat `word` as unreliable. |
| `top` | array | Up to 5 `{label, prob}` entries, descending, `prob > 0.01`. |
| `inference_micros` | integer | Python-side inference wall time in microseconds. |

### `error`

RFC 7807 Problem Details, wrapped for WS transport. Fatal errors are followed
by a close frame.

```json
{
  "schema_version": 1,
  "type": "error",
  "problem": {
    "type": "about:blank",
    "title": "Invalid landmark frame",
    "status": 400,
    "detail": "features must contain exactly 441 values, got 147"
  }
}
```

---

## Versioning rules

- Additive optional fields: no version bump; receivers ignore unknown fields.
- Field removal/rename, type change, dimension change, or new required field:
  bump `schema_version` here first, then update code (root DOX rule).
- The server rejects frames whose `schema_version` it does not support with an
  `error` (status 400) and closes the connection.
