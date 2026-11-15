# Starting and stopping the local LLM server without a password or docker access

> **Last verified:** 2026-11-04 on one machine (WSL2, Ubuntu 26.04) · **Status:** works for this machine; other systems not tried · **Scripts:** `scripts/setup/docker-gpu/sudo-local-llm.sh`, `aiw-llm-ctl.template`, `test-aiw-llm-ctl.sh`

## What this is, and whether you need it

`local-llm.sh start|stop|restart` runs a Docker container, and Docker needs root. Without this page's setup, every start and stop asks for the sudo password and goes through `sudo docker`, which works but is tiring. This setup installs one small root-owned program that can do only those few things, so the normal user needs neither the password nor docker access.

It is optional. `local-llm.sh` checks whether `/usr/local/sbin/aiw-llm-ctl` exists. If it does, all privileged work goes through it; if not, it falls back to `sudo docker`. So the same command behaves differently on a machine with and without it.

## Why not the `docker` group, or a sudoers rule for `docker run`

Both make any program that runs as you root-equivalent, because `docker run` accepts any mount and any flag (`-v /:/host`). The `docker` group is common and documented practice, so this is not a claim that it is wrong. The concern here is specific: a coding agent running on a small local model, in your account, which can run shell commands. With docker access, a mistake or a prompt injection in that session can read or write the whole machine as root. With the controller, the worst that session can do through it is start or stop this one container with a restricted set of options.

## What gets installed

| File | Owner, mode | What it is |
|---|---|---|
| `/usr/local/sbin/aiw-llm-ctl` | root:root, 0755 | the controller, generated from `aiw-llm-ctl.template` with this machine's values |
| `/etc/sudoers.d/aiw-local-llm` | root:root, 0440 | lets your user run exactly that file as root without a password |

The sudoers rule covers five forms: `stop`, `running`, `status-line`, `logs` and `start *`. It also sets `env_reset` and `!setenv`, so the caller cannot pass environment variables in. A copy of any file that existed before is kept in `/var/lib/aiw-local-llm-backup` (root-owned) and restored by `undo`. I checked on 2026-11-06 that the two installed files have the owners and modes above.

## What is fixed, and what the caller may choose

Fixed in the controller, never taken from the command line:

- the docker binary (`/usr/bin/docker`) and the container name (`aiw-local-llm`)
- the image, by digest
- the user (`--user uid:gid`): the container runs as you, not as root
- the mounts (model folder read-only, log folder, optionally the patched chat template read-only), `--gpus all`, `--entrypoint`
- the bind address `127.0.0.1` and the container-side port
- all capabilities dropped, `no-new-privileges`, read-only root file system, `/tmp` as a 1 GB tmpfs, a process limit

The caller may choose these, each checked against a strict pattern, or the call is refused:

| Option | Accepted |
|---|---|
| `--model-file` | a plain file name ending in `.gguf` that exists in the model folder |
| `--ctx` | a number from 512 to 2097152 |
| `--kv` | `f16` or `q8_0` |
| `--reasoning` | `on`, `off` or `auto` |
| `--threads` | 1 to 64 |
| `--port` | 1024 to 65535 (the host port) |
| `--log-name` | `server-YYYYMMDD-HHMMSS.log` |
| `--template` | a flag: use the patched chat template |

The API key is read as your user (so a symlink cannot make root read another file), must be 32 to 128 plain letters and digits, and goes to docker through the environment, never on a command line. The controller also refuses to run if sudo did not reset the environment (`BASH_ENV`, `LD_PRELOAD`, `DOCKER_*` and similar are set), and refuses a model or log folder whose path contains a symlink.

## How to review, install and undo it

The controller is a program that runs as root, so read it before installing it, and again after any change.

```bash
cd scripts/setup/docker-gpu
./sudo-local-llm.sh show          # print the controller and the sudoers rule exactly as they would be installed
./sudo-local-llm.sh apply --dry-run
./sudo-local-llm.sh apply         # asks for sudo once
./sudo-local-llm.sh status
./sudo-local-llm.sh undo          # removes both files, restores earlier versions
```

`apply` needs a pinned image first (`./llama-image.sh apply`). It stages the files in a root-owned folder, checks them (`bash -n`, `visudo -c`), prints their SHA-256 and the diff against what is installed, and asks before installing; `--yes` skips the question, not the printout. It then runs a self-test that never starts or stops the server: the no-password `running` call works, a path in `--model-file` is refused, an unknown option is refused, and `docker` itself still needs a password.

**If you only read one part of the template**, read the `start)` branch and the `docker run` line at its end: they hold everything that reaches docker.

## Limits

- Members of the `sudo` group can already run anything after a password. This only removes the password for those five commands; it does not restrict what you can do.
- Any process running as your user can now start and stop the server and occupy the GPU. It does not need your password to do so.
- The image digest is baked into the controller. After `llama-image.sh` pins a new image, run `apply` again.
- The model and log folders belong to your user, so a process running as you can change them between the controller's checks and docker mounting them. The window is small, and the container runs as you, so it gains nothing it did not already have; but it is not zero.
- The self-test warns when `net.ipv4.conf.all.route_localnet=1`, because with some Docker versions a port published on `127.0.0.1` can then be reached from the LAN.

## Security review

The first version was reviewed with Cloudflare's `security-audit-skill`, which produced five findings, fixed before the first install (commit e26f623). The audit report is not in this repository, so the list of five is not reproduced here. What the code itself shows of that hardening:

- files are installed from a root-owned staging folder, not from a user-writable one (the code calls this F1/F2): a process running as you cannot swap a file in after the check;
- the backup of an earlier file, and the "created by us" marker, live in a root-owned folder (F4): otherwise `undo` could be tricked into installing a user-written file as root;
- the API key is read as the user, and symlink checks cover the whole path of the model and log folders, not just the last component;
- the environment must already have been reset by sudo.

A later fix (commit a81a680) corrected the self-test itself: `sudo -l CMD` only says whether a command is allowed, and a `sudo`-group member is always allowed, so it falsely reported that docker ran without a password. It now actually tries `sudo -k -n docker --version`, which must be refused.

## What was verified

- `test-aiw-llm-ctl.sh`: 84 offline checks of the argument validation, with a stub docker (no sudo, GPU or docker needed). All pass on 2026-11-06; it is part of `make check`.
- 2026-11-04, on this machine: `apply` and its self-test passed, `status` and `restart` ran without a password, and the server process ran as the user, not as root.

Not verified: other Linux distributions, other sudo versions, hosts that are not WSL2, and the sudoers matching of the `start *` rule with options other than the ones `local-llm.sh` sends.
