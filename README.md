# nullbot-dist

Distribution package for **nullbot** — fleet observer that detects infrastructure problems and coordinates fixes through [Hiveram](https://hiveram.com). Ships with **chainwatch** policy gate because an unguarded agent is not a feature.

## What this is

Pre-built binaries and an install script that bootstraps any workstation with:
- **nullbot** — observes hosts, runs 43 detection runbooks, creates work orders in Hiveram
- **chainwatch** — policy gate that intercepts tool calls at irreversible boundaries

```
  nullbot (observe) ──► chainwatch (guard) ──► Hiveram (coordinate)
       │                      │                      │
  43 runbooks          allow/deny/approve      dedup + claims
  detect problems      enforce policy          one fix, not fifty
                              │
                     eBPF + seccomp (Linux)
                     kernel-level containment
```

## What this is NOT

- Not a monitoring tool — not Datadog, not Prometheus, not alerting
- Not an ML anomaly detector — deterministic policy, not probabilistic
- Not a web dashboard — CLI-first, coordination via API
- Not standalone — requires [Hiveram](https://hiveram.com) for work order coordination

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/ppiankov/nullbot-dist/main/install.sh | bash
```

The installer will:
1. Install chainwatch (policy gate) and bootstrap policy config
2. Install nullbot (fleet observer)
3. Configure Hiveram connection (API URL + key)
4. Optionally configure Groq API key for LLM-assisted observation
5. **On Linux**: set up eBPF/seccomp kernel-level enforcement (automatic)
6. Verify everything works

## Manual install

```bash
# 1. Download binaries for your platform
# macOS Apple Silicon
curl -LO https://github.com/ppiankov/nullbot-dist/releases/download/v1.5.1/chainwatch-darwin_arm64
curl -LO https://github.com/ppiankov/nullbot-dist/releases/download/v1.5.1/nullbot-darwin_arm64

# macOS Intel
curl -LO https://github.com/ppiankov/nullbot-dist/releases/download/v1.5.1/chainwatch-darwin_amd64
curl -LO https://github.com/ppiankov/nullbot-dist/releases/download/v1.5.1/nullbot-darwin_amd64

# Linux amd64
curl -LO https://github.com/ppiankov/nullbot-dist/releases/download/v1.5.1/chainwatch-linux_amd64
curl -LO https://github.com/ppiankov/nullbot-dist/releases/download/v1.5.1/nullbot-linux_amd64

# 2. Verify checksums
sha256sum -c checksums.txt

# 3. Install
sudo mv chainwatch-* /usr/local/bin/chainwatch
sudo mv nullbot-* /usr/local/bin/nullbot
chmod +x /usr/local/bin/chainwatch /usr/local/bin/nullbot

# 4. Bootstrap chainwatch
chainwatch init --profile clawbot

# 5. Configure nullbot
mkdir -p ~/.nullbot
cat > ~/.nullbot/config.yaml << 'EOF'
workledger:
  url: https://workledger.fly.dev/api/v1
  api_key_env: WORKLEDGER_API_KEY
EOF

# 6. Set secrets
mkdir -p ~/.workledger
echo "export WORKLEDGER_API_KEY='wl_your_key_here'" > ~/.workledger/api-key.env
chmod 600 ~/.workledger/api-key.env
echo '[ -f ~/.workledger/api-key.env ] && source ~/.workledger/api-key.env' >> ~/.zshrc
```

## 43 built-in runbooks

Runbooks are embedded in the nullbot binary. No separate download needed.

### Infrastructure
| Runbook | What it detects |
|---------|----------------|
| linux | System load, disk, memory, processes |
| storage | Disk usage, mount health, I/O bottlenecks |
| memory-pressure | OOM risk, swap usage, memory leaks |
| network | Interface errors, DNS, connectivity |
| systemd-health | Failed units, restart loops |
| nginx | Config errors, upstream failures |
| wordpress | PHP errors, plugin issues, DB connectivity |
| postfix | Mail queue, delivery failures |
| postfix-inbound | Inbound mail trace and delivery path |

### Kubernetes
| Runbook | What it detects |
|---------|----------------|
| kubernetes | Cluster health, pod failures, resource exhaustion |
| kubespectre | RBAC misconfig, exposed dashboards, privileged pods |
| k8s-utilization | Over/under-provisioned workloads |

### Cloud — AWS
| Runbook | What it detects |
|---------|----------------|
| cloud-infra | EC2, VPC, ELB, general AWS health |
| awsspectre | Public resources, security group exposure |
| aws-billing | Unexpected charges, billing anomalies |
| ecrspectre | Unscanned images, public repos |
| rdsspectre | Public endpoints, unencrypted storage |
| s3spectre | Public buckets, missing encryption |
| iamspectre | Over-provisioned roles, unused credentials |

### Cloud — GCP & Azure
| Runbook | What it detects |
|---------|----------------|
| gcpspectre | Public resources, IAM misconfig |
| gcsspectre | Public buckets, missing encryption |
| azurespectre | Resource exposure, identity misconfig |

### Databases
| Runbook | What it detects |
|---------|----------------|
| pgspectre | PostgreSQL permissions, public exposure |
| mysql | Replication lag, slow queries, connections |
| mongospectre | Auth bypass, public binding |
| redisspectre | No-auth, public binding, memory limits |
| clickhouse | Server health, query performance |
| clickhouse_config | Config drift from baseline |
| clickspectre | Network exposure, auth gaps |
| snowspectre | Snowflake access and permission audit |

### Cost & Capacity
| Runbook | What it detects |
|---------|----------------|
| cost-anomaly | Spend spikes, unexpected line items |
| spend-breakdown | Service-level cost attribution |
| idle-resources | Unused instances, detached volumes |
| reserved-capacity | Savings plan gaps, RI utilization |
| resource-sizing | Over-provisioned compute and storage |
| aispectre | LLM API spend waste |

### Observability & CI
| Runbook | What it detects |
|---------|----------------|
| prometheus | Scrape failures, storage issues |
| elasticspectre | Elasticsearch cluster security |
| logspectre | Secret leakage in log pipelines |
| kafkaspectre | Topic ACLs, consumer lag |
| cispectre | CI/CD pipeline security gaps |

### Security
| Runbook | What it detects |
|---------|----------------|
| vaultspectre | HashiCorp Vault seal status, policy gaps |
| dnsspectre | Dangling records, subdomain takeover risk |

## Kernel-level enforcement (Linux)

On Linux hosts with kernel ≥5.8 and BTF support, the installer automatically sets up eBPF observation and seccomp enforcement via systemd:

- **`nullbot.service`** — runs the nullbot daemon
- **`chainwatch-enforce.service`** — attaches eBPF tracepoints to the nullbot process tree and applies seccomp filters using the `nullbot-enforce` containment profile

The `nullbot-enforce` profile blocks 35 syscalls across 5 groups:

| Group | What it blocks | Examples |
|-------|---------------|----------|
| baseline | Dangerous system calls | mount, ptrace, reboot |
| privilege_escalation | UID/GID changes | setuid, setgid, capset |
| file_mutation | Destructive file operations | unlink, rename, chmod, truncate |
| mount_admin | Kernel module and mount operations | init_module, pivot_root |
| network_egress | Raw outbound connections | connect, sendto, socket |

The enforcement service binds to the nullbot lifecycle — it starts and stops with nullbot. If eBPF is unavailable (containers, old kernels), the installer skips enforcement with a warning. Audit log at `/var/log/chainwatch/enforce.jsonl` with 14-day logrotate.

```bash
# Check enforcement status
systemctl status chainwatch-enforce

# Start both services
systemctl start nullbot

# View denial audit log
tail -f /var/log/chainwatch/enforce.jsonl
```

macOS does not support eBPF — enforcement is skipped silently. The userspace policy gate (chainwatch) still applies on all platforms.

## Platforms

| OS | Architecture | Status |
|----|-------------|--------|
| macOS | Apple Silicon (arm64) | Supported |
| macOS | Intel (amd64) | Supported |
| Linux | amd64 | Supported |
| Linux | arm64 | Supported |

## Known limitations

Nullbot is structurally contained, not "safe." The enforcement stack prevents specific failure classes, not all failure classes.

**What containment covers:**
- Tool calls intercepted before execution (userspace policy gate)
- 35 dangerous syscalls blocked at kernel level (seccomp)
- Syscall-level observation of what the agent actually does (eBPF)
- Agent cannot modify its own config or weaken its guard

**What containment does NOT cover:**
- **Logic errors** — the agent can still do wrong things within allowed operations (bad queries, wrong configs, misleading reports)
- **Data exfiltration via allowed channels** — nullbot talks to Hiveram by design; seccomp blocks raw `connect`, but allowed API endpoints remain open
- **Prompt injection via host output** — a compromised host can inject instructions into command output that the LLM classification step processes
- **Binary replacement** — if someone replaces the chainwatch binary on disk, the systemd unit runs the replacement. No runtime integrity verification
- **macOS** — no kernel-level enforcement; userspace policy gate only

Containment reduces the blast radius. It does not eliminate risk. Deploy with the same operational discipline you would apply to any privileged automation.

## Prerequisites

- A [Hiveram](https://hiveram.com) account (API key)
- Optional: [Groq](https://groq.com) API key for LLM-assisted observation

## License

[Business Source License 1.1](LICENSE) — use freely for internal and self-hosted deployments. See LICENSE for details.
