# Claude Code on a local model (llama.cpp in Docker, WSL2)

> **Last verified:** 2026-11-02 · **Status:** draft, works for short interactive sessions; quality and long sessions not yet measured here · **Claude Code:** 2.1.317 · **Server:** llama.cpp build 12033 (commit 785322d17, image pinned by digest) · **Model:** Qwen3.8-27B `UD-IQ3_XXS`
>
> Machine and quantisation data: `qwen-27b-quantisation-16gb.md`. Scripts: `scripts/setup/docker-gpu/local-llm.sh`, `claude-local.sh`, `gguf_template.py`.

## What this gives you

A local HTTP endpoint that speaks the Anthropic Messages API, so one Claude Code session can run on your own GPU instead of Anthropic's models. By configuration, requests in that session go only to `127.0.0.1`; I did not confirm that with a packet capture.

It does not replace the cloud model for hard work. Use it for small, well-bounded tasks and keep the normal `claude` for the rest.

## Run it

```bash
cd scripts/setup/docker-gpu
./local-llm.sh start        # about 1 minute; checks /v1/messages and /v1/messages/count_tokens itself
cd <your project>
<path>/claude-local.sh      # one Claude Code session on the local model; your normal `claude` is untouched
./local-llm.sh stop         # when done: frees the GPU
```

`local-llm.sh start` refuses to run if a benchmark or anything else already holds the GPU, and `claude-local.sh` refuses to start if the server is not healthy.

### From another machine (for example a Mac)

The server listens only on the GPU machine's `127.0.0.1`. `claude-local.sh` detects that there is no local key file and switches to remote mode: it reads the API key over SSH, opens a tunnel (`ssh -N -L`, bound to `127.0.0.1` on your machine, local port 18080), runs the session, and closes the tunnel when the session ends.

```bash
# once, on the other machine: tell the script which SSH host to use. The name is NOT stored in this repository.
mkdir -p ~/.config/ai-workstation
echo 'LOCAL_LLM_SSH_HOST=<your-ssh-alias>' > ~/.config/ai-workstation/private.env
# then, in the project you want to work on:
<path>/claude-local.sh
```

- The server must already be running (`./local-llm.sh start` on the GPU machine; starting it needs sudo, so it cannot be done remotely by this script).
- Needs `ssh` key login (it runs with `BatchMode`, so it never stops at a prompt), `curl`, `python3` and `claude` on the other machine. It is written to run on macOS's bash 3.2.
- If something already listens on the tunnel port, the script refuses to send the key to it. `--reuse-tunnel` overrides that when the listener is your own tunnel.
- The server has one slot: two sessions at the same time queue behind each other.
- Arguments the script does not know go to `claude`: `./claude-local.sh --resume`.
- Tested on Linux with a stand-in `ssh`, server and `claude`: both modes, the tunnel closing after the session, the exit code passing through, the key absent from every command line.
- Confirmed on a real Mac (2026-11-02): the remote mode works, with the SSH host pointing at the machine's Tailscale name, so it no longer depends on the LAN address or a `.local` name (see `../base/tailscale-wsl.md`). What was checked: the session starts and answers. Not measured: the macOS bash version used, and long sessions.

### Defaults and why

| Setting | Value | Reason |
|---|---|---|
| Model | `UD-IQ3_XXS` | the only quant that gives the long context a coding agent needs (about 101K fits) |
| KV cache | q8_0 | about twice the context of f16 for 1-9 % speed (see the quantisation recipe) |
| Context | 98304, one slot | leaves a little headroom under the 101K limit |
| GPU layers | all (`-ngl 99 -fit off`) | fails loudly if it does not fit, instead of silently spilling to the CPU |
| Reasoning | on (the model's default) | `--reasoning off` is available; the difference in a coding session is not measured |
| Binding | `127.0.0.1:8080`, API key required | the key is generated once, stored mode 600, and kept out of logs and command lines |
| Server log | `~/.local/state/ai-workstation/local-llm/server-logs/server-<time>.log` | one file per start, kept after stop or a crash (the container itself is removed on stop, with its logs). Added after a problem could not be investigated because the log was gone; not yet confirmed on a real start |

**GPU headroom is small:** with these settings the card showed 15,499 of 16,303 MiB used, about 800 MiB free. If the Windows desktop takes more GPU memory (video, many windows) the server can fail with a CUDA out-of-memory error. Restart with `--ctx 65536`.

### What `claude-local.sh` sets

Only the environment of that one process (and the same non-secret values through `--settings`, because an `env` block in a settings file overrides the shell and could redirect the requests). The token is passed in the environment only.

| Variable | Value | Purpose |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:8080` | where requests go (no `/v1`) |
| `ANTHROPIC_AUTH_TOKEN` | the generated key | auth; never on a command line |
| `ANTHROPIC_MODEL` and the default model for every role, subagents forced | `local-qwen` | a role not mapped would send a `claude-*` name the server does not know |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | 98304 | it assumes 200000 for an unknown model |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | 50 | compaction by percentage; the window variable has a 100000 floor, above this context |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | 16000 | |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | 1 | no updates or telemetry |
| `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` | 1 | commands the model runs do not inherit the token |
| `NO_PROXY` | loopback added | a project-level proxy setting cannot capture the requests |

Permission mode is pinned to `default`: every file edit or command asks you. Do not use auto mode here; its safety classifier would be the same weak local model.

These values come from an earlier private project on Windows (Claude Code 2.1.309); they were not re-measured here beyond "the session starts and works".

## Problems met, and the fixes

### 1. HTTP 500 "System message must be at the beginning"

Symptom: Claude Code shows `500 ... Retrying in 3s attempt 6/10` and the server log has a Jinja exception at `raise_exception('System message must be at the beginning.')`.

Cause: the Qwen3.8 chat template accepts system messages only at the start of the conversation and raises on a later one. A request with a late system message can never succeed, so the client retries until it gives up.

I reproduced the exception with a plain Jinja render of the template on `[system, user, assistant, system, user]`.

Fix: `gguf_template.py` reads the model file's own template from the GGUF metadata and changes the line that raises, so a late system message is rendered as a system turn. It refuses to write anything unless each line to patch occurs exactly once. `local-llm.sh` mounts the result into the container and passes `--chat-template-file`; `--no-template-fix` turns this off.

Not known: which component sends the late system message (Claude Code or the server's conversion of Anthropic requests). The patch stops the failure; whether the model uses such a message well was not tested, because the model was not trained on system turns in mid-conversation.

### 1b. HTTP 500 "Unexpected item type in content"

Symptom (seen on the Mac session, through the tunnel): `API Error: 500 ... raise_exception('Unexpected item type in content.')`.

Cause: the same template accepts only `text`, `image` and `video` items inside a message's content and raises on any other block type. Which block type Claude Code sent is not known: the error does not say, and the request body was not captured.

Fix: a second patch in `gguf_template.py`. A `thinking` or `redacted_thinking` block is dropped silently; any other unknown block is replaced by the visible text `[content of type X omitted]` instead of an error. So if the model ever mentions such a marker, the name in it is the block type that was being sent, which is the clue to look for. The patch was tested with a plain Jinja render (the original raises, the patched one renders), and then on the real server: it started with the patched template and a multi-turn Mac session ran without the 500. No `[content of type ... omitted]` marker has appeared so far, so the block that triggered the error was probably a `thinking` block, which is dropped silently; that is a guess.

Trade-off: silently dropping or replacing a block means the model does not see it. For thinking blocks this is harmless. For other types (for example a document) it can hide content, which is why the marker is not silent.

### 2. Sandbox: "missing socat"

Symptom: the local session reports that sandbox initialisation failed because `socat` is missing, and its Bash tool stops working.

Cause: Claude Code's Bash sandbox on Linux and WSL2 needs `bubblewrap` (already installed) and `socat` (was not). It was not enabled in `~/.claude/settings.json`; where it was switched on is not established.

Fix: `sudo apt install -y socat`, then restart the local session (the server stays up). After that Bash works.

### 2b. WebSearch: "Did 0 searches"

Symptom: a question that needs current information makes the session call `Web Search(...)`, which reports `Did 0 searches`; the model then guesses URLs for `Fetch` and gets 404s, or keeps retrying (one earlier session ended with `response exceeded the 16000 output token maximum`; that case was not captured, so its cause is not established).

Cause: `WebSearch` is executed by Anthropic's servers, not by Claude Code on your machine. A local server does not run it. `WebFetch` runs locally and works, but the model has no way to know a correct URL.

Fix: `claude-local.sh` passes `--disallowedTools WebSearch` unless you give your own `--disallowedTools`. Questions that need the web ("latest news") are not a job for this setup: use the cloud model. Local sessions suit work that depends only on the project's files.

### 3. Notices that need no action

- *"claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth source is set"*: expected. The session authenticates with the local token, not your account, so account connectors (mail, drive) are not loaded.
- *"auto mode ... classifier billing ... your requests go through 127.0.0.1:8080, which isn't compatible"*: the session is not eligible for a billing change that concerns a gateway; nothing breaks. Auto mode is not used here, and requests to a local server cost nothing.

### 4. `sudo` password on every start and stop

A one-line drop-in raises the sudo password cache from 15 minutes to 8 hours. It is per terminal window (sudo's default), and it adds no privilege:

```bash
echo 'Defaults timestamp_timeout=480' > /tmp/aiw-timeout.sudoers
sudo visudo -c -f /tmp/aiw-timeout.sudoers            # must say "parsed OK"
sudo install -m 440 -o root -g root /tmp/aiw-timeout.sudoers /etc/sudoers.d/aiw-timeout
rm -f /tmp/aiw-timeout.sudoers
# undo: sudo rm -f /etc/sudoers.d/aiw-timeout
```

Adding the user to the `docker` group, or a `NOPASSWD` rule for `docker`, would also remove the prompt but is equivalent to giving that user root (a container can mount `/`), so it was not done. A restricted root-owned wrapper that can only start and stop this one container is the safer permanent option; not built.

## What was verified, and what was not

Verified (from the logs of 2026-11-02):

- The pinned image serves `POST /v1/messages` (Anthropic message format, with a `thinking` block and a `text` block) and `/v1/messages/count_tokens`.
- The server was ready 63 s after start.
- With the patched template a Claude Code session on the local model works, including the Bash tool after `socat` was installed.

Not verified:

- Coding quality and speed inside real Claude Code sessions (no task log yet: task, time, corrections needed, tests passing).
- Long sessions. An earlier measurement on a similar 3-bit 27B with a 65K window found that sessions which read many files tended to fail at Claude Code's own context compaction. This machine has a larger window (98K) and was not tested for that.
- The `thinking` blocks come back with an empty `signature` field; it caused no visible problem in short sessions.
- That no request leaves the machine (by configuration only).

## Reproduce / undo

`./local-llm.sh undo` stops the server and deletes only the files it generated (the API key, the patched template). Logs and traces stay under `~/.local/state/ai-workstation/local-llm/`.
