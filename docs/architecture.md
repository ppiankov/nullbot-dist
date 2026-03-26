# Nullbot Protection Architecture

How the protection stack is wired on a ClickHouse (or any Linux arm64) host.

## Zero trust principle

Nothing leaves the host unscanned. Both outbound channels (LLM provider and Hiveram) route through separate pastewatch proxy instances. Binaries are locked with immutable flags after installation.

## Data flow

```
                          ┌──────────────────────┐
                          │   LLM Provider       │
                          │   (Groq/OpenAI/etc.) │
                          └──────────▲───────────┘
                                     │ HTTPS
                          ┌──────────┴───────────┐
                          │  pastewatch proxy     │
                          │  :8443                │   ◄── scans LLM request/response
                          │  redact secrets       │       audit: /var/log/pastewatch/proxy.jsonl
                          │  inject alerts        │
                          └──────────▲───────────┘
                                     │ http://127.0.0.1:8443
                                     │
┌────────────────────────────────────┼──────────────────────────────────────────┐
│  HOST (Linux arm64)                │                                          │
│                                    │                                          │
│  ┌─────────────────────────────────┴────────────────────────────────────┐    │
│  │                                                                      │    │
│  │  chainwatch enforce --profile nullbot-enforce                        │    │
│  │  ├── eBPF: tracepoints on exec, file, net, privesc                  │    │
│  │  ├── seccomp: 35 syscalls blocked                                   │    │
│  │  └── audit: /var/log/chainwatch/enforce.jsonl                       │    │
│  │                                                                      │    │
│  │  ┌────────────────────────────────────────────────────────────┐     │    │
│  │  │  nullbot daemon                                            │     │    │
│  │  │                                                            │     │    │
│  │  │  ┌──────────────┐     ┌────────────────────────────┐      │     │    │
│  │  │  │ 43 runbooks  │────►│ LLM calls ──► :8443 proxy │      │     │    │
│  │  │  │ detect       │     │ (secrets redacted)         │      │     │    │
│  │  │  │ problems     │     └────────────────────────────┘      │     │    │
│  │  │  └──────┬───────┘                                         │     │    │
│  │  │         │                                                  │     │    │
│  │  │         ▼                                                  │     │    │
│  │  │  ┌──────────────────────────────────────────────────┐     │     │    │
│  │  │  │ WO create ──► :8444 proxy ──► Hiveram            │     │     │    │
│  │  │  │ (runbook output scanned for secrets before send) │     │     │    │
│  │  │  └──────────────────────────────────────────────────┘     │     │    │
│  │  │                                                            │     │    │
│  │  └────────────────────────────────────────────────────────────┘     │    │
│  │                                                                      │    │
│  └──────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│                          ┌──────────┴───────────┐                            │
│                          │  pastewatch proxy     │                            │
│                          │  :8444                │   ◄── scans WO payloads   │
│                          │  redact secrets       │       audit: hiveram.jsonl │
│                          └──────────┬───────────┘                            │
│                                     │ http://127.0.0.1:8444                  │
│  Binaries: chattr +i (immutable)    │                                        │
│  Logs: 14-day rotate                │                                        │
└─────────────────────────────────────┼────────────────────────────────────────┘
                                      │ HTTPS
                          ┌───────────▼──────────┐
                          │   Hiveram (remote)    │
                          │   workledger.fly.dev  │
                          │   WO storage, dedup   │
                          │   claims, memory sync │
                          └──────────────────────┘
```

## Protection layers

```
Layer 0: Network
  UFW / iptables — only SSH + outbound HTTPS
  No inbound except management

Layer 1: Binary integrity
  chattr +i on /usr/local/bin/{chainwatch,nullbot,pastewatch-cli}
  Immutable flag — even root cannot modify without explicitly clearing
  Prevents binary replacement attacks
  To update: chattr -i, replace, chattr +i

Layer 2: Kernel enforcement (eBPF + seccomp)
  chainwatch enforce --profile nullbot-enforce
  ├── seccomp: blocks 35 syscalls (setuid, ptrace, mount, reboot, unlink, etc.)
  ├── eBPF: tracepoints on exec, file, net, privesc — full audit
  └── Audit log: /var/log/chainwatch/enforce.jsonl

Layer 3: Policy gate (chainwatch)
  Intercepts tool calls at irreversible boundaries
  ├── allow / deny / require-approval decisions
  ├── Deterministic policy, not ML
  └── Agent cannot modify its own policy

Layer 4: Secret redaction — LLM traffic (pastewatch proxy :8443)
  Scans outbound LLM API traffic
  ├── Request bodies: strips secrets before they reach the LLM provider
  ├── Response bodies: scans for reflected secrets
  ├── Alert injection: nullbot sees redaction events
  └── Audit log: /var/log/pastewatch/proxy.jsonl

Layer 5: Secret redaction — Hiveram traffic (pastewatch proxy :8444)
  Scans outbound WO payloads (titles, notes, sections)
  ├── Runbook output may contain discovered secrets
  ├── Secrets stripped before reaching Hiveram
  └── Audit log: /var/log/pastewatch/hiveram.jsonl

Layer 6: Coordination (Hiveram)
  Nullbot reports findings as work orders via HTTP API
  ├── Deduplication: same finding from N hosts = 1 WO
  ├── Claims: one agent fixes, others skip
  ├── Memory sync: context survives agent restarts
  └── No direct host access — API only
```

## What cannot happen

| Attack | Prevention |
|--------|-----------|
| Secret leaks to LLM provider | pastewatch proxy :8443 redacts before forwarding |
| Secret leaks to Hiveram | pastewatch proxy :8444 redacts WO payloads |
| Privilege escalation | seccomp blocks setuid/setgid/capset + NoNewPrivileges=true |
| File system destruction | seccomp blocks unlink/rename/chmod/truncate |
| Kernel module loading | seccomp blocks init_module/finit_module |
| Agent modifies its own config | ProtectHome=read-only, ProtectSystem=strict |
| Agent disables its guard | seccomp is kernel-enforced, cannot be removed from userspace |
| Binary replacement | chattr +i immutable flag, requires CAP_LINUX_IMMUTABLE to clear |
| Agent opens raw network sockets | seccomp blocks socket/connect/sendto (allowed via proxy only) |
| LLM bypass (direct connection) | NULLBOT_LLM_BASE_URL forced to 127.0.0.1:8443 by systemd |
| Hiveram bypass (direct connection) | WORKLEDGER_URL forced to 127.0.0.1:8444 by systemd |

## Secret leak response

When pastewatch proxy detects and redacts a secret from any outbound request:

1. **Redact** — secret is replaced with `[REDACTED:type]` before leaving the host
2. **Alert** — pastewatch injects an alert into the response (--alert flag)
3. **Nullbot sees the alert** — treats it as a critical finding
4. **P0 WO created** — in Hiveram: "Secret leak detected: [type] — rotate immediately"
5. **Audit logged** — full event with timestamp, type, severity, source context
6. **The secret never left the host**

## Startup order

```
systemctl start chainwatch-enforce

1. pastewatch-proxy.service      ── LLM proxy on :8443
2. pastewatch-hiveram.service    ── Hiveram proxy on :8444
3. chainwatch-enforce.service    ── eBPF + seccomp + nullbot daemon
   └── nullbot daemon
       ├── loads 43 runbooks
       ├── LLM calls → :8443 → provider
       ├── WO calls → :8444 → Hiveram
       └── begins observation cycle
```

## File locations

```
Binaries (immutable):
  /usr/local/bin/chainwatch       — policy gate
  /usr/local/bin/nullbot           — fleet observer
  /usr/local/bin/pastewatch-cli    — secret scanner + proxy

Config:
  ~/.nullbot/config.yaml           — hiveram URL, LLM settings
  ~/.nullbot/llm.env               — LLM API key, upstream URL, proxy URL
  ~/.workledger/api-key.env        — Hiveram API key
  ~/.chainwatch/                   — policy profiles

Systemd:
  /etc/systemd/system/pastewatch-proxy.service     — LLM proxy
  /etc/systemd/system/pastewatch-hiveram.service   — Hiveram proxy
  /etc/systemd/system/chainwatch-enforce.service   — enforcement + nullbot
  /etc/systemd/system/nullbot.service              — standalone (no enforcement)

Logs:
  /var/log/chainwatch/enforce.jsonl    — eBPF/seccomp audit
  /var/log/pastewatch/proxy.jsonl      — LLM secret detection
  /var/log/pastewatch/hiveram.jsonl    — Hiveram payload scanning
```

## Known limitation: prompt injection

A compromised host can inject instructions into command output that nullbot's LLM classification step processes. This is an inherent risk of running LLM-assisted observation on untrusted hosts.

Mitigations:
- Deterministic runbooks execute first (no LLM involved)
- LLM classification is assistive, not authoritative — findings must match runbook patterns
- All LLM traffic goes through pastewatch proxy (secrets stripped from context)
- seccomp prevents the agent from acting on injected instructions (destructive syscalls blocked)

This does NOT fully prevent a sophisticated injection from producing misleading WO content. The structural answer is: treat WO content from untrusted hosts as untrusted input. Hiveram consumers should validate before acting.

## Platforms

| Host | Enforcement | LLM Proxy | Hiveram Proxy | Immutable | Status |
|------|-------------|-----------|---------------|-----------|--------|
| Linux arm64 (ClickHouse) | eBPF + seccomp | :8443 | :8444 | chattr +i | Full stack |
| Linux amd64 | eBPF + seccomp | :8443 | :8444 | chattr +i | Full stack |
| macOS (dev) | none | manual | manual | none | Partial |
