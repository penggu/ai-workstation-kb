# Strata: network behaviour and API-key enforcement (terminal 0.1.56)

> **Last verified:** 2026-11-05 · **Status:** source and docs reading plus one read-only `ss` look; **no packet capture**; live auth test added in the section "Live verification" · **Strata terminal:** 0.1.56 (commit `974074c`, linux-x86_64) · **Engine component:** 0.1.56 (cuda13) · **Upstream:** github.com/Niko1221/Strata (docs/SAFETY.md is byte-identical at that commit and at HEAD `9f7d977`)
>
> Context: issue #19. Related: `docs/recipes/claude-code-local.md` (Strata backend on 127.0.0.1:8090).

## Question

1. What network connections does Strata make at install, idle and while serving, and does the upstream "no telemetry" claim hold?
2. Does `strata launch --access local` with `--api-key` / `--api-key-env` / `--new-key` really enforce authentication on 127.0.0.1:8090, and can the key be changed without a restart?

## Method

- Read upstream docs: `docs/SAFETY.md`, `SECURITY.md`, via `gh api repos/Niko1221/Strata/contents/...`. Checked SAFETY.md at the installed commit: identical to HEAD.
- Read the installed Python source in `~/.local/share/strata/terminal/0.1.56` (path prefixes below are relative to it; test files and the bundled `python/` were excluded). Searched for `urllib`, `http.client`, `socket`, `ssl`, `telemetry`, `sentry`/`posthog`/`mixpanel`, every `http(s)://` literal, `api_key`, `Bearer`, `401`/`403`, host binding and access modes.
- Read-only observation (first session, before the keyed restart described in "Live verification") of the running launch (profile `launch-q2_0-128k`, started with host `127.0.0.1`, port 8090, no key): `ss -tnap` / `ss -unap` filtered to its three PIDs, and one `GET /health`. Nothing was restarted, loaded or changed, and no auth probe was sent to it.
- The engine binary (`components/engine/.../strata`) was **not** inspected; only upstream's statement about it is cited.

## Findings (1): network

### Install and update (explicit, user-triggered)

| Step | Destination in source | Evidence |
|---|---|---|
| `strata launch` when no engine/model is present, `strata update` | signed feed `https://github.com/Niko1221/Strata/releases/latest/download/strata-feed.json` | `strata_cli/update_cmd.py:35`; `strata_cli/launch/runner.py:746-757` |
| Model files | `huggingface.co` (or `HF_ENDPOINT`), `modelscope.cn` only with `--source modelscope` | `setup.py:108,155`; `tools/mtp_fetch.py:43`; docs/SAFETY.md "When Strata uses the internet" |
| llama.cpp prep scripts | `github.com/ggml-org/llama.cpp` at a pinned commit | `setup.py:238` |
| Connectivity probe | `HEAD https://github.com`, UA `strata-setup` | `setup.py:8397` |
| Build-from-source extras (PyPI, NVIDIA, ROCm nightlies) | only when running setup from a checkout | `setup.py:3768,3794-3803` |

The README says only `strata launch` and `strata update` fetch files (`README.txt`); `strata serve`, `runtime`, `monitor` "never install or download anything".

### Idle and serving

- **Observed (2026-11-05, WSL2, after ~7 min uptime, first snapshot; a longer sample is in "Live verification"):** the three Strata processes (`strata_control.runtime` pid 33811, `serve.server` pid 33819, engine pid 33839) had **no ESTABLISHED TCP sockets and no UDP sockets**. The only socket was `LISTEN 127.0.0.1:8090` (pid 33819). This is a single snapshot, not a time series.
- **Server code:** the only outbound-capable calls in `serve/` are (a) `Vision.download()` fetching an `http(s)` image URL **only when a client request contains one** (`serve/server.py:3137-3159`, UA `strata`), and (b) the MCP client to servers the user lists in the run config (`serve/mcp.py:284-286,375`). `serve/telemetry.py` is a local hardware sampler (NVML, sysfs, psutil, `/proc`) for the Monitor tab, not a reporter (`serve/telemetry.py:1-12`). No Sentry/PostHog/Mixpanel/crash-report code was found by grep outside Windows `PROCESSENTRY32W` and a comment.
- **Offline switch:** `strata_control/offline.py` sets `HF_HUB_OFFLINE`, `DO_NOT_TRACK`, empty proxies etc. for child processes, and states that it cannot stop a child that opens sockets directly (offline.py docstring). `STRATA_OFFLINE=1` is set at `serve/server.py:4082`.
- **The one quiet background call (launch monitor only):** `strata_cli/launch/monitor_ext.py:62` starts `engine_update.start_daily_check`, which reads the signed update feed (a few KB, 5 s limit, once per 24 h, silent on failure) unless `STRATA_UPDATE_CHECK=0` (`strata_control/engine_update.py:69,79-110,113`). It runs in the TUI monitor, not in the server process. Upstream documents this as "one quiet exception" (docs/SAFETY.md, "An engine is never updated by itself"). It is a request to GitHub, so GitHub sees your IP and a time; it sends no usage payload that I could see in `refresh_cache`, but I did not read `updater.check()`'s request headers (unverified).
- **Tunnels:** `--access cloudflare` runs `cloudflared tunnel --no-autoupdate --url http://127.0.0.1:PORT` (`strata_cli/launch/access.py:395`); Tailscale is only read, not driven (docs/SAFETY.md table). Neither applies to `--access local`.
- **Local-only calls by the launcher:** `/metrics` and readiness polling go to `127.0.0.1` (`strata_cli/launch/runner.py:2166,2194`).

### Does "no telemetry" hold?

- Upstream claim: "There is no telemetry. Strata sends no usage data, no crash reports and no analytics" and "Does Strata phone home? No." (docs/SAFETY.md lines 12 and 25-29).
- **Consistent with the code I read:** no analytics/crash library, no usage-reporting code path, server idle shows no outbound sockets. The things named telemetry in the code (`/metrics`, `/v1/telemetry`, `serve/telemetry.py`) are local hardware readings, gated by the API key when one is set (`serve/server.py:7518-7534`; SECURITY.md).
- **Qualifications:** (a) the daily update-feed read exists and is on by default in the launch monitor; (b) image-URL fetching and MCP are request/config driven; (c) the engine binary and the separate DeepSeek coding-agent component were not audited by me, upstream says the engine has no networking code and the agent's telemetry is switched off at start; (d) "no outbound sockets" is one snapshot.
- **Doc/code mismatch to note:** SAFETY.md says `strata launch` updates an installed DeepSeek engine package by itself (lines 13-14, 49), while 0.1.56 `strata_cli/launch/runner.py:2526-2535` says a launch "never reaches the update feed" and only prints a cached notice, and a later SAFETY.md paragraph says the same as the code. The Qwen model on this machine is unaffected; flag it as an upstream doc inconsistency, not a telemetry finding.

## Findings (2): authentication

### Does `--access local` + a key enforce auth?

By source, yes.

- `--api-key KEY`, `--api-key-env NAME` (errors if the variable is empty) set `s.api_key`; `--new-key` generates one (`strata_cli/launch/cmd.py:279-285,917-919`). `--no-api-key` with a key given keeps the key (cmd.py:286-289).
- `derive_config` writes `cfg["host"] = acc.host_for(access)` (`127.0.0.1` for `local`, also for `cloudflare`; `0.0.0.0` for lan/tailscale: `strata_cli/launch/access.py:32`) and `cfg["api_key"] = s.api_key` **whenever a key is set, regardless of access mode** (`strata_cli/launch/runner.py:538-545`). Only the "key required/auto-generated" logic is skipped for `local` (`cmd.py:439-441`; `settings.py:218`), so local defaults to no key unless you pass one.
- The server reads the key once at start: `raw_key = a.api_key or cfg.get("api_key")` (`serve/server.py:9669`), `svc.api_key = preflight_api_key` (`9896`). An empty/whitespace key aborts start rather than meaning "no key" (`api_key_of`, 8801-8815; `9674-9677`).
- Enforcement: `_authorized()` returns 401 `authentication_error` unless `Authorization: Bearer <key>` or `x-api-key` matches (`serve/server.py:7416-7423`); comparison is `hmac.compare_digest`, several comma-separated keys allowed (`key_matches`, 8819-8830; `key_list`, 8775-8784). It gates **every POST** (`_post`, 7826), `/v1/models`, `/status`, `/props`, `/slots`, `/v1/status`, `/metrics`, `/metrics/prometheus`, `/settings`, `/config`, `/mcp`, `/api/requests`, `/tool-media/` (the `_authorized()` call sites at 7440-7814; `/v1/telemetry` accepts the main or a separate telemetry key, 7426-7434, 7533).
- **Not gated:** `GET /health` and `/api/health` (it even reports `"api_key": true/false`, `serve/server.py:7741-7744`), the chat page `/` and static files/fonts, and `/v1/images/files/<random name>` (name is the secret, 7745-7747). Treat `/health` as a free "is a key set" oracle.
- **Side effect of a key:** the DNS-rebinding Host check and the cross-site Origin check are skipped when a key is set because "with a key the key decides" (`serve/server.py:7285-7293,7309`; SECURITY.md). Without a key those two checks are what protect 127.0.0.1 from a browser page; with a key, the key is the only protection.
- Clients: Strata's own launcher and checks send the key as both `Authorization: Bearer` and `x-api-key` (`strata_cli/launch/check.py:39-40`). For Claude Code via `claude-local.sh`, use the existing `STRATA_TOKEN_FILE` path from the recipe.
- Secret handling: the key is stored in the private run config (`~/.local/state/strata/launch/<name>.json`) and preset file (`settings.py:134` comment: "stored only in the private preset file"). The server process command line on this machine shows `--config <path>` and no key. `--api-key KEY` on the `strata launch` command line is visible in `ps` and shell history during the launch; prefer `--api-key-env`.

### Can the key change without a restart?

By source, **no**.

- `svc.api_key` is assigned exactly once (grep for `.api_key =` finds only `serve/server.py:4513` default and `9896`). There is no reload path.
- The web page's `/config` and `/settings` edit only the whitelist in `serve/runconfig.py:22-43` (sampling, aliases, idle_unload_s, mtp, ...), which excludes `api_key`, host and port. SECURITY.md: `/config` is "never the network, key, MCP or program keys".
- `strata launch` treats the key as part of the server identity: `choices()` includes a SHA-256 fingerprint of the key (`runner.py:1954-1962`), so a changed key counts as "different choices". Docs: different choices ask once on the screens, and with `--no-tui` refuse unless `--restart` (docs/TERMINAL_LAUNCH.md, "Launching while a model is serving"); `--yes` never restarts a running model (TERMINAL_LAUNCH.md flag table). So rotation = restart = model unload and reload.
- A new launch with no key flag **keeps** the earlier key for non-local access (`access.kept_key`, `cmd.py:438-443`; "`--new-key` and the key button are the only ways to rotate it", `access.py:320-323`). Show it with `strata launch --show-key`.
- Consequence for this machine, at the time of the first reading (it was later restarted with a key, see "Live verification"): the running server had no key (`GET /health` returned `"api_key": false`; its config has no `api_key` entry, checked as a boolean only), so adding one means one restart.

## What is still unverified, and how to verify

Done on 2026-11-05 (see "Live verification"): auth enforced with a key (401 without or with a wrong key, 200 with the right one, on GET and POST), `/health` open with `"api_key": true`, Claude Code through a keyed Strata with `STRATA_TOKEN_FILE`, and a 2-minute network sample. What remains, replace `<...>` placeholders:

1. **Key change needs a restart:** run the same `strata launch` with a different `--api-key-env` value and **without** `--restart --no-tui`; expect a one-line refusal naming the running model. Also confirm the running server still answers with the old key.
2. **`--new-key` and local:** `strata launch ... --access local --new-key --restart` then `strata launch --show-key`, and repeat the 401/200 checks with that key.
3. **Idle/serving network, over time:** for 15 min idle, then during 5 requests, sample every 5 s:
   ```bash
   P=$(pgrep -d'|' -f 'serve.server|strata_control.runtime|components/engine')
   for i in $(seq 180); do ss -tnap | grep -E "pid=($P)" | grep -v 127.0.0.1; ss -unap | grep -E "pid=($P)"; sleep 5; done | sort | uniq -c
   ```
   Expect empty output. Also run once with `strata monitor`/the launch TUI open to see the daily feed read (it connects to GitHub only if the `~/.local/share/strata/components` state is older than 24 h). For proof rather than a sample, use a packet capture or a network namespace without a route out.
4. **Engine binary and request headers of the daily check:** not inspected; check with `strings` on the engine for URLs, and with the capture above while the monitor runs.
5. **A longer Claude Code coding session with file edits on Strata** (issue #18).

## Sources

- Upstream, `gh api repos/Niko1221/Strata/contents/<path>`: `docs/SAFETY.md` (lines 12-15, 25-40, 45-80, 88-100), `SECURITY.md` (lines 18-40, 52-71). Commit `9f7d977` (HEAD, 2026-11-05); SAFETY.md compared with the installed commit `974074c` and identical. Latest release tag at fetch time: `v0.2.11`.
- Installed `~/.local/share/strata/terminal/0.1.56/`: `README.txt`, `docs/TERMINAL_LAUNCH.md`, `serve/server.py`, `serve/telemetry.py`, `serve/runconfig.py`, `serve/mcp.py`, `strata_cli/launch/{cmd,runner,access,settings,check,monitor_ext}.py`, `strata_cli/update_cmd.py`, `strata_control/{engine_update,offline}.py`, `setup.py`, line numbers as cited inline.
- Runtime observation: `ss -tnap`, `ss -unap`, `GET http://127.0.0.1:8090/health` on 2026-11-05.


## Live verification (2026-11-05, same issue)

Strata was no longer running, so it was started fresh with `--access local --port 8090 --api-key-env STRATA_API_KEY` (key from a mode-600 file, checked with `stat -c %a`: 600). Observed:

| Request to `127.0.0.1:8090` | Result |
|---|---|
| `GET /v1/models`, no key | 401 |
| `GET /v1/models`, wrong Bearer | 401 |
| `GET /v1/models`, right `Authorization: Bearer` | 200 |
| `GET /v1/models`, right `x-api-key` | 200 |
| `GET /status`, no key | 401 |
| `POST /v1/messages`, no key (the route that uses the GPU) | 401 |
| `GET /health`, no key | 200, `"api_key": true` |

So the source reading above is confirmed for `--access local` with a key. Claude Code through `claude-local.sh --backend strata` with `STRATA_TOKEN_FILE` returned a correct answer to a real `-p` prompt, and two `POST /v1/messages` calls with the key succeeded.

Network sample: `ss -tnup` every 5 s for 2 minutes (idle, then two requests). The Strata processes (terminal, serve, engine) had no non-loopback connection in a final per-process check; the sampling loop (filtered by process name) recorded none either. `ss -p` without root can hide processes of other users, which is why the machine-wide list is only context. Limits: one 2-minute window, no packet capture, and three non-loopback sockets in the machine-wide list had no visible owner (not attributed to Strata, not proven otherwise). The sampling loop's first filter matched process names, so the per-process check is the stronger evidence.

Still unverified: see the list in the previous section.

Not tested on the load side: a streamed prompt beyond the two short requests, and a `local-llm.sh` style "start refuses an unauthenticated request" check (not built into `strata.sh`; see issue #16).
