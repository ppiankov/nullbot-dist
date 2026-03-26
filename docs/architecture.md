# Nullbot Protection Architecture

How the protection stack is wired on a ClickHouse (or any Linux arm64) host.

## Data flow

```
                                    ┌─────────────────────────────────┐
                                    │        Hiveram (remote)         │
                                    │   workledger.fly.dev/api/v1     │
                                    │                                 │
                                    │   WO storage, dedup, claims     │
                                    │   Memory sync, coordination     │
                                    └──────────┬──────────────────────┘
                                               │ HTTPS
                                               │ Bearer token auth
                                               │
┌──────────────────────────────────────────────┼──────────────────────────────────────┐
│  HOST (Linux arm64)                          │                                      │
│                                              │                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐    │
│  │  systemd                                                                    │    │
│  │                                                                             │    │
│  │  ┌─────────────────────────┐                                                │    │
│  │  │ pastewatch-proxy.service│ ◄── starts first (Before=nullbot)              │    │
│  │  │                         │                                                │    │
│  │  │ :8443 ──► upstream LLM  │     Scans ALL outbound LLM request/response    │    │
│  │  │           (Groq/OpenAI/ │     bodies for secrets. Redacts before forward. │    │
│  │  │           Anthropic/    │     Audit log: /var/log/pastewatch/proxy.jsonl  │    │
│  │  │           OpenRouter)   │     On detection: injects alert into response   │    │
│  │  └────────────▲────────────┘     so nullbot sees the finding.               │    │
│  │               │                                                             │    │
│  │               │ http://127.0.0.1:8443                                       │    │
│  │               │ (NULLBOT_LLM_BASE_URL)                                      │    │
│  │               │                                                             │    │
│  │  ┌────────────┴────────────┐                                                │    │
│  │  │ chainwatch-enforce.svc  │ ◄── OR nullbot.service (without enforcement)   │    │
│  │  │                         │                                                │    │
│  │  │ chainwatch enforce \    │     eBPF: attaches tracepoints to process tree │    │
│  │  │   --profile nullbot \   │     seccomp: blocks 35 dangerous syscalls      │    │
│  │  │   -- nullbot daemon     │     Audit log: /var/log/chainwatch/enforce.jsonl│   │
│  │  │                         │                                                │    │
│  │  │  ┌───────────────────┐  │                                                │    │
│  │  │  │     nullbot       │  │     43 runbooks, detect problems               │    │
│  │  │  │                   │  │     Creates WOs in Hiveram via HTTPSink        │    │
│  │  │  │  observe ──► WO   │──┼────► Hiveram (WO create, dedup, claim)         │    │
│  │  │  │                   │  │                                                │    │
│  │  │  │  LLM calls ──────┼──┼────► pastewatch proxy ──► LLM provider         │    │
│  │  │  │                   │  │                                                │    │
│  │  │  └───────────────────┘  │                                                │    │
│  │  └─────────────────────────┘                                                │    │
│  │                                                                             │    │
│  └─────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                      │
│  Logs:                                                                               │
│    /var/log/chainwatch/enforce.jsonl  ── syscall audit (14-day rotate)               │
│    /var/log/pastewatch/proxy.jsonl   ── secret detection audit (14-day rotate)       │
│                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

## Protection layers

```
Layer 0: Network
  UFW / iptables — only SSH + outbound HTTPS
  No inbound except management

Layer 1: Kernel enforcement (eBPF + seccomp)
  chainwatch enforce --profile nullbot-enforce
  ├── seccomp: blocks 35 syscalls (setuid, ptrace, mount, reboot, unlink, etc.)
  ├── eBPF: tracepoints on exec, file, net, privesc — full audit
  └── Audit log: /var/log/chainwatch/enforce.jsonl

Layer 2: Policy gate (chainwatch)
  Intercepts tool calls at irreversible boundaries
  ├── allow / deny / require-approval decisions
  ├── Deterministic policy, not ML
  └── Agent cannot modify its own policy

Layer 3: Secret redaction (pastewatch proxy)
  Scans outbound LLM API traffic on localhost:8443
  ├── Request bodies: strips secrets before they reach the LLM provider
  ├── Response bodies: scans for reflected secrets
  ├── Alert injection: nullbot sees redaction events
  ├── Severity threshold: high (configurable)
  └── Audit log: /var/log/pastewatch/proxy.jsonl

Layer 4: Coordination (Hiveram)
  Nullbot reports findings as work orders via HTTP API
  ├── Deduplication: same finding from N hosts = 1 WO
  ├── Claims: one agent fixes, others skip
  ├── Memory sync: context survives agent restarts
  └── No direct host access — API only
```

## Secret leak response

When pastewatch proxy detects and redacts a secret from an outbound LLM request:

1. **Redact** — secret is replaced with `[REDACTED:type]` before reaching the LLM provider
2. **Alert** — pastewatch injects an alert into the LLM response (--alert flag)
3. **Nullbot sees the alert** — treats it as a critical finding
4. **WO created** — P0 work order in Hiveram: "Secret leak detected — rotate [type]"
5. **Audit logged** — full event in `/var/log/pastewatch/proxy.jsonl`

The secret never leaves the host. The WO triggers rotation.

## Startup order

```
systemctl start chainwatch-enforce  (or: systemctl start nullbot)

1. pastewatch-proxy.service  ── starts first (Before= dependency)
   └── listening on :8443

2. chainwatch-enforce.service  ── starts second
   ├── attaches eBPF tracepoints
   ├── applies seccomp filter
   └── launches nullbot daemon as child process

3. nullbot daemon
   ├── loads runbooks
   ├── connects to Hiveram (WO API)
   ├── LLM calls route through 127.0.0.1:8443 (pastewatch proxy)
   └── begins observation cycle
```

## File locations

```
Binaries:
  /usr/local/bin/chainwatch       — policy gate
  /usr/local/bin/nullbot           — fleet observer
  /usr/local/bin/pastewatch-cli    — secret scanner + proxy

Config:
  ~/.nullbot/config.yaml           — hiveram URL, LLM settings
  ~/.nullbot/llm.env               — LLM API key, upstream URL, proxy URL
  ~/.workledger/api-key.env        — Hiveram API key
  ~/.chainwatch/                   — policy profiles

Systemd:
  /etc/systemd/system/pastewatch-proxy.service
  /etc/systemd/system/chainwatch-enforce.service
  /etc/systemd/system/nullbot.service

Logs:
  /var/log/chainwatch/enforce.jsonl    — eBPF/seccomp audit
  /var/log/pastewatch/proxy.jsonl      — secret detection audit
```

## Platforms

| Host | Enforcement | Proxy | Policy | Status |
|------|-------------|-------|--------|--------|
| Linux arm64 (ClickHouse) | eBPF + seccomp | pastewatch proxy | chainwatch | Full stack |
| Linux amd64 | eBPF + seccomp | pastewatch proxy | chainwatch | Full stack |
| macOS (dev) | none (no eBPF) | pastewatch proxy | chainwatch | Partial |
