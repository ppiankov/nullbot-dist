# Quickstart

Three commands. Works on any Linux host (amd64 or arm64).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ppiankov/nullbot-dist/main/install.sh | bash
```

The installer asks:

| Prompt | What to enter |
|--------|--------------|
| Host profile | Pick your server type (ClickHouse, AWS, Kubernetes, etc.) |
| Hiveram URL | Your Hiveram endpoint (default: workledger.fly.dev) |
| Hiveram API key | From your team admin or dashboard |
| LLM API key | Optional — skip for deterministic-only mode |
| LLM provider | Groq, OpenAI, Anthropic, OpenRouter, or custom |

Everything else is automatic: proxies, enforcement, binary locking.

## Start

```bash
systemctl start chainwatch-enforce
```

This starts the full stack in order:
1. pastewatch proxy (LLM traffic on :8443)
2. pastewatch proxy (Hiveram traffic on :8444)
3. chainwatch enforcement (eBPF + seccomp)
4. nullbot daemon (observation begins)

## Verify

```bash
systemctl status chainwatch-enforce
```

All green = running with full protection.

## Useful commands

```bash
# Live observation log
journalctl -u chainwatch-enforce -f

# Check all services
systemctl status pastewatch-proxy pastewatch-hiveram chainwatch-enforce

# View secret detection audit
tail -f /var/log/pastewatch/proxy.jsonl

# View enforcement audit
tail -f /var/log/chainwatch/enforce.jsonl

# List available runbooks
nullbot runbooks

# Run a one-off observation (outside systemd)
nullbot observe --scope /var/lib/clickhouse --type clickhouse

# Stop everything
systemctl stop chainwatch-enforce
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ppiankov/nullbot-dist/main/uninstall.sh | bash
```

Or if you cloned the repo:

```bash
./uninstall.sh
```

## Profiles

| Profile | Use when | Runbooks |
|---------|----------|----------|
| ClickHouse | ClickHouse servers | clickhouse, clickhouse_config, clickspectre, linux, storage, memory-pressure |
| AWS infra | EC2/VPC/IAM management | cloud-infra, awsspectre, iamspectre, s3spectre, rdsspectre, cost-anomaly, + 5 more |
| Kubernetes | K8s nodes | kubernetes, kubespectre, k8s-utilization, prometheus, network |
| Web server | nginx/wordpress | nginx, wordpress, linux, network, systemd-health |
| Database | Postgres/MySQL/Redis/Mongo | pgspectre, mysql, redisspectre, mongospectre, linux, storage |
| Mail server | Postfix | postfix, postfix-inbound, dnsspectre, linux, network |
| General | Any Linux host | linux, storage, network, systemd-health, memory-pressure |
| Security audit | Full security scan | All 21 spectre runbooks |
| Custom | You choose | Any combination |

## What's running

```
pastewatch-proxy.service    :8443  → scans LLM traffic for secrets
pastewatch-hiveram.service  :8444  → scans WO payloads for secrets
chainwatch-enforce.service         → eBPF + seccomp + nullbot daemon
```

All outbound traffic is scanned. Binaries are immutable. 35 dangerous syscalls are blocked at kernel level.

See [architecture.md](architecture.md) for the full protection stack diagram.
