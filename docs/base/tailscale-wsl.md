# Reaching a WSL2 machine at a stable address with Tailscale

> **Last verified:** 2026-11-02 · **Status:** works (SSH from a Mac confirmed) · **Tailscale:** 1.104.5 (stable apt repository) · **OS:** Ubuntu 26.04 "resolute" in WSL2 (mirrored networking, systemd on)
>
> Script: `scripts/setup/tailscale/tailscale.sh`.

## Why

A machine on home Wi-Fi gets a different LAN address after a router lease change, and `.local` (mDNS) names are unreliable over Wi-Fi: here the name stopped resolving on the other machine while the host itself was fine. A fixed DHCP reservation was not possible on this router. Tailscale gives each machine a stable address and name that works from the same room or from another network.

## Where to install it: in WSL

Everything that is reached remotely (sshd, the local model server) lives in WSL, so Tailscale is installed there.

| | In WSL (chosen) | On Windows |
|---|---|---|
| Reaching sshd and the model server | direct | goes through mirrored networking; not tested here |
| Windows / Hyper-V firewall rules (LAN only) | not involved: Tailscale traffic is encapsulated in UDP | the Tailscale address range would need an allow rule |
| Reaching Windows itself (remote desktop) | no | yes |
| Survives `wsl --shutdown` | no: the node goes offline until WSL starts again | yes |

Do not install it on both sides of the same machine: two Tailscale interfaces under mirrored networking invite routing confusion.

## Install

```bash
cd scripts/setup/tailscale
./tailscale.sh status          # nothing changed yet
./tailscale.sh apply --dry-run
./tailscale.sh apply           # asks for sudo once; the last step prints a URL: open it, sign in, approve this machine
```

| Step | What it does |
|---|---|
| t1 | adds the apt source and signing key from `pkgs.tailscale.com` (the same two files the official `install.sh` writes); first checks that the server lists the Ubuntu release as supported |
| t2 | installs `tailscale` and `tailscale-archive-keyring` |
| t3 | enables and starts `tailscaled` (the package already does this, so the step usually reports "already done") |
| t4 | `tailscale up --accept-dns=false --accept-routes=false --ssh=false`, then waits for you to approve in a browser |

The official `install.sh` was downloaded and read (SHA-256 `4207f322e10ad26b3054abe7c99dfb54da09843c8d0a50d0a82f8eff4972a0d1`, 2026-11-02) and its apt branch reproduced as t1/t2; it is not executed by this script.

### Flags that were chosen on purpose

- `--ssh=false`: Tailscale SSH would take over from the existing key-only `sshd` (port 2222 here). Not wanted.
- `--accept-dns=false`: Tailscale would otherwise rewrite WSL's `/etc/resolv.conf`, which can disturb Docker and package downloads. Checked after install: the file does not mention Tailscale. MagicDNS names are resolved by the *other* machine's own Tailscale client; WSL does not need them.
- No routes, no exit node.

## Check

```bash
tailscale status                # this machine and the others on the account
ip -br addr | grep tailscale0   # the interface exists (state UNKNOWN is normal for it)
grep -ci tailscale /etc/resolv.conf   # 0: DNS untouched
ss -ltn | grep :2222            # sshd still listening
```

From the other machine, with Tailscale signed in to the same account:

```bash
nc -z -w 3 <tailscale-address> 2222 && echo reachable
ssh -p 2222 <user>@<tailscale-address>      # confirmed to work from a Mac
```

Then put the Tailscale name or address in that machine's `~/.ssh/config` as the `HostName`; it no longer changes. These names and addresses belong in your private notes, not in a public repository.

## Updating

`./tailscale.sh update` compares the installed and candidate versions, asks, and upgrades only the two Tailscale packages. It is separate from `apply` on purpose, and automatic updates were not turned on. A security fix should not wait long, so run it every month or two.

## Undo

```bash
./tailscale.sh undo            # asks first; reverse order: logout, stop service, purge packages, remove the repo files it created
```

The machine stays in the Tailscale admin console's list until you delete it there.

## Things to know

- An account that has been used before may list old devices (offline for months). Remove the ones you no longer use in the admin console: each is a key that could still be used.
- By default every device on the account can reach every other device. Tailscale access rules (ACLs) can restrict that, for example to one device and one port. Not configured here.
- Signing in needs an identity provider account (Google, Microsoft or GitHub). The coordination service sees which devices are online and when; traffic itself is end to end encrypted.
- The model server from `claude-code-local.md` still listens on `127.0.0.1` only; use it through an SSH tunnel as described there. That the Claude Code remote mode works over the Tailscale address was not tested.

## Not verified

- Behaviour after `wsl --shutdown` or a Windows reboot (whether the node comes back without help).
- Access rules, Tailscale-side key expiry settings, and the connection from outside the home network.
