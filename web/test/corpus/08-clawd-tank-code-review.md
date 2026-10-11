# Code Review: Tasks 7–11 (Python Host)

**Date:** 2026-03-11
**Reviewer:** code-reviewer agent
**Scope:** protocol.py, ble_client.py, socket_server.py, daemon.py, clawd-notify, install-hooks.sh, test_protocol.py, test_daemon.py
**Spec compliance:** pre-confirmed by spec-checker

---

## Code Review Summary

The Python host is well-structured with clear module separation and sensible async design. However, there is one real concurrency bug (dict mutation mid-iteration), a thread-safety concern in the BLE disconnect callback, and several smaller issues in error handling and resource cleanup.

---

## Critical Issues ⚠️

### 1. Dict mutation during iteration in `_replay_active` — `daemon.py:43`

```python
async def _replay_active(self) -> None:
    for msg in self._active_notifications.values():   # iteration starts
        payload = daemon_message_to_ble_payload(msg)
        await self._ble.write_notification(payload)
        await asyncio.sleep(0.05)                     # yields event loop here
```

`asyncio.sleep(0.05)` yields the event loop. While suspended, the socket server can accept a new connection and call `_handle_message`, which does `self._active_notifications[session_id] = msg` or `.pop(...)`. If the dict changes size during iteration, Python raises `RuntimeError: dictionary changed size during iteration`.

**Fix:** Snapshot the values before iterating:
```python
for msg in list(self._active_notifications.values()):
```

---

## High Priority Issues 🔴

### 2. `_on_disconnect` mutates `asyncio.Event` from a non-loop thread — `ble_client.py:52`

```python
def _on_disconnect(self, client: BleakClient) -> None:
    self._connected.clear()   # asyncio.Event is not thread-safe
    self._client = None
```

Bleak calls disconnect callbacks from its internal thread (or loop thread depending on platform). `asyncio.Event.clear()` is not thread-safe when called outside the event loop thread. Should be:
```python
loop = asyncio.get_event_loop()
loop.call_soon_threadsafe(self._connected.clear)
```
Setting `self._client = None` from a non-loop context is also a read/write race with `is_connected` and `write_notification`.

### 3. `_shutdown_event` not in `__init__` — `daemon.py:58,91`

```python
async def _shutdown(self) -> None:
    self._shutdown_event.set()   # line 58 — AttributeError if called before run()
    ...
async def run(self) -> None:
    self._shutdown_event = asyncio.Event()   # line 91 — too late
```

If `_shutdown()` is called before `run()` (e.g., a signal fires before the event loop reaches line 91), this raises `AttributeError`. Move `self._shutdown_event = asyncio.Event()` to `__init__`.

### 4. `asyncio.get_event_loop()` deprecated — `daemon.py:93`

```python
loop = asyncio.get_event_loop()
```

Deprecated since Python 3.10; inside `asyncio.run()`, the correct call is `asyncio.get_running_loop()`. `get_event_loop()` may emit a DeprecationWarning and will stop working in a future Python version.

### 5. `session_id` accessed with `[]` not `.get()` — `protocol.py:45,52`

```python
"id": msg["session_id"],   # KeyError if key missing
```

`project` and `message` use `.get()` with defaults, but `session_id` uses `[]`. A malformed message from the socket would raise `KeyError` and crash `_ble_sender`. Use `msg.get("session_id", "")` for consistency and safety.

### 6. Socket not closed on send failure — `clawd-notify:74`

```python
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(3.0)
sock.connect(str(SOCKET_PATH))
sock.sendall(json.dumps(msg).encode("utf-8"))
sock.close()   # not reached if sendall raises
```

If `sendall` raises, the socket is leaked. Use `try/finally` or a context manager.

---

## Medium Priority Issues 🟡

### 7. `socket_server` reads without length framing — `socket_server.py:39`

```python
data = await asyncio.wait_for(reader.read(4096), timeout=5.0)
```

`reader.read(4096)` reads *up to* 4096 bytes. A JSON message larger than 4096 bytes (possible if hook message text is long) will be silently truncated and fail to parse. For robustness, use `reader.readuntil(b'\n')` (with newline-terminated sends) or a length-prefix protocol. The sender (`clawd-notify`) doesn't add a newline terminator currently.

### 8. Failed BLE write drops the message — `daemon.py:79`

```python
success = await self._ble.write_notification(payload)
if not success:
    await self._ble.ensure_connected()
    await self._replay_active()   # replays active_notifications, not the failed msg
```

On write failure the current message is not retried — it's silently dropped. For `dismiss` events this is especially bad: `_handle_message` already removed the session from `_active_notifications` before the write, so `_replay_active` won't include it. The ESP32 will still show the dismissed notification.

### 9. `_ble_sender` dies silently on `ValueError` — `daemon.py:76`

```python
payload = daemon_message_to_ble_payload(msg)   # raises ValueError on unknown event
```

If an unknown event is dequeued, `daemon_message_to_ble_payload` raises `ValueError`, the `_ble_sender` task crashes, and the daemon becomes permanently deaf to new notifications (no log, no restart). Wrap in `try/except ValueError` with a log.

### 10. Double `_remove_pid()` call — `daemon.py:65,115`

`_remove_pid()` is called at the end of `_shutdown()` (line 65) and again in `run()` (line 115). The second call is harmless (existence check prevents errors) but confusing. Remove one.

### 11. Dead code: `DAEMON_MODULE` — `clawd-notify:24`

```python
DAEMON_MODULE = Path(__file__).parent / "clawd_daemon" / "daemon.py"
```

Defined but never used. The daemon is launched via `-m clawd_daemon.daemon`. Delete it.

### 12. `_connected` Event in `ClawdBleClient` is never awaited — `ble_client.py:19`

`self._connected = asyncio.Event()` is set/cleared correctly but nothing ever `await`s it. `ensure_connected` checks `is_connected` (a property), not the event. The Event is dead code. Either use it (e.g., `await self._connected.wait()`) or remove it.

---

## Low Priority Suggestions 🔵

### 13. `sys.exit(1)` in hook may be too loud — `clawd-notify:81`

Claude Code hooks that exit non-zero may surface errors to the user or interrupt the tool call chain. Since the notification feature is non-critical (Claude works fine without it), `sys.exit(0)` after logging to stderr may be more appropriate.

### 14. `start_daemon()` opens log file without `try/finally` — `clawd-notify:46`

```python
log_file = open(CLAWD_DIR / "daemon.log", "a")
subprocess.Popen([...], stdout=log_file, ...)
log_file.close()
```

If `Popen` raises, `log_file` is leaked. Use `with open(...) as log_file:` or a `try/finally`.

### 15. Broad `except Exception` in `socket_server._handle_client` — `socket_server.py:43`

All errors — `JSONDecodeError`, `RuntimeError`, `asyncio.TimeoutError` — are caught and logged as the same message. At minimum log the traceback (`logger.exception(...)` instead of `logger.error(...)`), and consider distinguishing JSON parse errors (client bug) from timeout (client too slow).

### 16. Missing tests in `test_protocol.py`

- `clear` event path in `daemon_message_to_ble_payload` (the `{"action": "clear"}` branch)
- Unknown event raises `ValueError`
- `cwd=""` yields `project="unknown"`
- Missing `session_id` field (defaults to `""`)

### 17. Missing tests in `test_daemon.py`

- `_replay_active` behavior (especially that it sends current active notifications)
- BLE write failure → reconnect → replay path
- Snapshot behavior: new `add` arriving during replay doesn't raise `RuntimeError` (regression test for issue #1)

### 18. `install-hooks.sh` missing `set -u` and executable check

```bash
set -e   # already present
set -u   # missing — unbound variable references expand silently
```

Also: no check that `clawd-notify` is executable (`[ -x "$CLAWD_NOTIFY" ]`). A common install mistake.

---

## Positive Highlights ✨

- **`protocol.py` is a clean pure-function module.** No side effects, easy to test, well-documented. The `None`-return contract for irrelevant events is an elegant way to let callers skip processing.
- **`ble_client.py` lock usage is correct.** `asyncio.Lock` around GATT writes prevents concurrent writes from multiple tasks.
- **`is_daemon_running()` handles stale PID files gracefully.** Catches `ProcessLookupError`, `ValueError`, `PermissionError` — covers the real failure modes.
- **`socket_server.py` sets `0o600` on the Unix socket.** Correct security default — only the owner can connect.
- **`socket_server.py` unlinks the socket on both start and stop.** Handles leftover sockets from crashed daemons cleanly.
- **`daemon.py` replay-on-reconnect design is solid.** Tracking `_active_notifications` separately from the queue means a reconnect can sync the ESP32 to current state.
- **Signal handling for SIGTERM/SIGINT is correct.** Using `loop.add_signal_handler` (not `signal.signal`) is the right approach in asyncio.
- **`clawd-notify` lazy-start pattern is clean.** Check PID, start if missing, poll for socket — straightforward and correct for a CLI tool.
- **`test_daemon.py` tests behavior, not mocks.** Calling `_handle_message` directly and asserting on `_active_notifications` and queue size tests real logic without any mocking.
- **`install-hooks.sh` is correctly conservative** — outputs config rather than writing it, avoiding silent overwrites of existing hook configs.

---

## Recommendations

1. **Fix the `_replay_active` dict mutation bug** (issue #1) — one-line fix: `list(self._active_notifications.values())`. Add a regression test.
2. **Fix `_on_disconnect` thread safety** (issue #2) — use `call_soon_threadsafe`.
3. **Move `_shutdown_event` to `__init__`** (issue #3) — straightforward.
4. **Replace `get_event_loop()` with `get_running_loop()`** (issue #4).
5. **Fix the `session_id` KeyError** (issue #5) — use `.get()`.
6. **Fix socket leak in `clawd-notify`** (issue #6) — `try/finally sock.close()`.
7. **Add length framing to socket protocol** (issue #7) — even a simple `msg + b'\n'` / `reader.readuntil(b'\n')` is enough.
8. **Add the `list()` snapshot and regression test** immediately — this is the only bug that causes a runtime exception in normal use.
