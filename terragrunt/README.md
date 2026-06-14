# Watchtower on AWS — Terragrunt

Infrastructure-as-code for running **Watchtower's production observability stack
(LGTM + Alloy)** on AWS, in Terragrunt. Same conventions as the Conduct stack —
if you haven't read `conduct/terragrunt/README.md` §1 ("The mental model"),
read that first; it explains the `root.hcl` / `account.hcl` / `env.hcl` /
`region.hcl` / `_envcommon` / unit hierarchy that both repos share. This doc
focuses on what's *different* about Watchtower.

> **Status:** skeleton, not applied. `account.hcl` has placeholders. Validated
> with `terragrunt hcl fmt` (clean), `terragrunt hcl validate` (0 errors), and
> `tofu validate` on every local module (all pass — this caught one real bug, a
> wrong cluster-module argument, now fixed). The registry-module *input* shapes
> for the ECS **service** units (especially `service_connect_configuration`)
> should still be confirmed with a real `terragrunt plan` against pinned
> versions — see [Validate further](#validate-further).

---

## 1. What's deployed — and what isn't

**Deployed (production traffic): LGTM + Alloy.**

| Component | Module | What it is |
|-----------|--------|------------|
| `vpc` | registry vpc | network (public for ALB/NAT, private for tasks), 3 AZs |
| `security-groups` | local | ALB SG + one app SG for all tasks (intra-stack allow + OTLP from Conduct) |
| `ecr` | local `ecr-repos` | one image repo per service (baked config images — see §3) |
| `s3` | local `s3-buckets` | object-storage backends for **Loki** (chunks) + **Tempo** (traces) |
| `secrets` | local `app-secrets` | Grafana admin password (Secrets Manager) |
| `efs` | registry efs | persistent volumes for **Prometheus** (TSDB) + **Grafana** (its DB) |
| `acm` | registry acm | TLS cert for the Grafana hostname |
| `ecs-cluster` | local | Fargate cluster + **Service Connect namespace** (§4) |
| `alb` | registry alb | public HTTPS load balancer → Grafana UI |
| `nlb` | registry alb (network) | **internal** load balancer → Alloy OTLP (Conduct peers in) |
| `dns` | local `route53-alias` | Grafana public A record (latency-routed in prod) |
| `ssm` | local `ssm-params` | publishes OTLP endpoint + Grafana URL for Conduct (§7) |
| `service-tempo` / `-loki` / `-prometheus` / `-grafana` / `-alloy` | registry ecs service | the five Fargate services |

**NOT deployed: SonarQube** (and its Postgres). SonarQube is a *local build-quality*
tool — it never serves production traffic — so it stays on the local
docker-compose stack and is intentionally excluded from AWS. A nice side effect:
Watchtower's cloud footprint needs **no RDS** at all.

### Mapping from `docker-compose.yml`

| compose service | becomes |
|-----------------|---------|
| `tempo` | `service-tempo` (S3-backed) |
| `loki` | `service-loki` (S3-backed) |
| `prometheus` | `service-prometheus` (EFS TSDB) |
| `grafana` | `service-grafana` (EFS, behind ALB) |
| `alloy` | `service-alloy` (behind internal NLB) |
| `sonarqube`, `sonarqube-db` | **dropped** (local-only) |
| `./docker/*-config.yaml` bind mounts | baked into images (§3) |
| host volumes | S3 (loki/tempo) or EFS (prometheus/grafana) |

---

## 2. Storage model (why each backend)

- **Loki + Tempo → S3.** Both natively support S3 object storage. The tasks
  become effectively stateless; durability + retention are S3's job (a lifecycle
  rule expires old data). Each service's task role grants only its own bucket.
- **Prometheus → EFS.** Prometheus's local TSDB needs a real filesystem; EFS
  gives it one that survives task replacement. (Scalable alternative: Amazon
  Managed Prometheus — noted in §11.)
- **Grafana → EFS.** Its SQLite DB + provisioned state. (Alternative: point
  Grafana at an RDS Postgres — but we dropped RDS with Sonar, and SQLite-on-EFS
  is fine for a single Grafana task.)

---

## 3. Baked config images (the key Watchtower-specific decision)

ECS has no equivalent of a Kubernetes ConfigMap or a docker-compose bind mount,
so each service's config file has to get *into* the container some other way.
The idiomatic ECS answer — and what this stack assumes — is to **bake the config
into a thin image**: `FROM` the upstream image, `COPY` the config in, push to the
per-service ECR repo. Immutable, versioned, no runtime fetch.

You will add a small Dockerfile per service, e.g.:

```dockerfile
# docker/aws/loki.Dockerfile
FROM grafana/loki:2.9.3
COPY loki-config.aws.yaml /etc/loki/loki-config.yaml
```

…and build/push each to its ECR repo (tag = the `image_tag` you set in
`env.hcl`):

```bash
ACCOUNT=111122223333; REGION=us-west-2; TAG=2026-06-14
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
for svc in tempo loki prometheus grafana alloy; do
  docker buildx build --platform linux/arm64 \
    -f docker/aws/$svc.Dockerfile \
    -t "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/watchtower-prod-$svc:$TAG" --push .
done
```

**The configs differ from the local ones** — that's the work this stack sets up
but doesn't write for you. The AWS variants need:

- **Loki / Tempo:** `storage` backend = `s3`, bucket from the `*_S3_BUCKET` env
  var (run with config env-expansion), region from `AWS_REGION`. Credentials come
  from the task role (no keys).
- **Prometheus:** keep `--web.enable-remote-write-receiver`; `--storage.tsdb.path=/prometheus`
  (the EFS mount).
- **Grafana datasources:** point at the **Service Connect names** —
  `http://loki:3100`, `http://tempo:3200`, `http://prometheus:9090` (see §4).
- **Alloy:** OTLP receivers on `0.0.0.0:4317/4318`; exporters to those same
  Service Connect names (`loki:3100` push, `tempo:3200`, `prometheus:9090`
  remote-write).

> Tradeoff: a config change means rebuild+push that image. If you'd rather edit
> config without rebuilds, the alternative is to stage configs on EFS and mount
> them — at the cost of a more awkward "how do files get onto EFS" story. Baked
> images are the default here.

---

## 4. Service discovery (ECS Service Connect)

The `ecs-cluster` unit creates a **Service Connect namespace**. Each backend
service (`loki`, `tempo`, `prometheus`) *advertises* a `client_alias` (e.g.
`loki:3100`) via its `service_connect_configuration`. Grafana and Alloy are
*clients* (Service Connect enabled, no advertised service) and reach the
backends by those names. This is why the Grafana datasources and Alloy exporters
above use bare hostnames — no IPs, no per-backend internal load balancers. All of
this traffic stays inside the single app security group.

---

## 5. Dependencies & order of operations

```
vpc
├── security-groups
│   ├── efs           (also needs vpc)
│   ├── alb           (also needs vpc public subnets + acm)
│   └── nlb           (also needs vpc private subnets)
├── ecr
├── s3
├── secrets
├── acm
└── ecs-cluster

alb ── dns
nlb ── ssm

service-tempo       needs: ecs-cluster, vpc, security-groups, ecr, s3
service-loki        needs: ecs-cluster, vpc, security-groups, ecr, s3
service-prometheus  needs: ecs-cluster, vpc, security-groups, ecr, efs
service-grafana     needs: ecs-cluster, vpc, security-groups, ecr, efs, alb, secrets
service-alloy       needs: ecs-cluster, vpc, security-groups, ecr, nlb
```

First-time order:
1. Fill in `account.hcl`; AWS creds; the S3 state bucket + lock table auto-create.
2. Apply `ecr`, then **build & push the 5 baked images** (§3).
3. Set `image_tag` in `env.hcl`; `terragrunt run-all apply` the region.
4. Set the Grafana admin password secret (§6).
5. Repeat in `us-east-2` for prod.

---

## 6. Secrets & env vars you set yourself

- **Grafana admin password** (Secrets Manager container `watchtower/<env>/grafana-admin-password`,
  injected as `GF_SECURITY_ADMIN_PASSWORD`):
  ```bash
  aws secretsmanager put-secret-value --secret-id watchtower/prod/grafana-admin-password \
    --secret-string "$(openssl rand -hex 24)"
  ```
- **`image_tag`** in `env.hcl` — the tag you pushed the baked images under (bump per release).
- **`account.hcl`** — `account_id`, unique `state_bucket`, the Grafana DNS zone, and
  `otlp_allowed_cidrs` (Conduct's VPC CIDRs that may send OTLP — pre-filled to match
  Conduct's `region.hcl` plan).

Non-secret env (set for you): `AWS_REGION`, the `*_S3_BUCKET` vars for Loki/Tempo,
`GF_SECURITY_ADMIN_USER=admin`, `GF_SERVER_ROOT_URL` (from the Grafana domain).

---

## 7. Cross-stack: Conduct ⇄ Watchtower

1. **VPC peering.** Conduct's VPCs (10.1x/10.2x) and Watchtower's (10.4x/10.5x)
   are non-overlapping by design. Peer them so Conduct's tasks can reach Alloy's
   internal NLB. (The peering connection itself isn't in either stack yet — it's
   the one piece that spans both; add it as a small dedicated unit in whichever
   stack you prefer, or by hand to start. Flagged as a follow-up, not hidden.)
2. **Discovery via SSM.** The `ssm` unit publishes
   `/watchtower/<env>/<region>/otlp-endpoint` (Alloy's NLB) and `…/grafana-url`.
   Conduct reads those values into its `env.hcl` (`otlp_endpoint`, `grafana_url`).
3. **Order:** bring Watchtower up first so those SSM values exist, then point
   Conduct at them.

---

## 8. Multi-region observability

Each region runs its **own full LGTM stack with its own S3 buckets** — telemetry
stays in-region (Conduct in us-east-2 → Watchtower in us-east-2). Grafana is
latency-routed so you reach the nearest one. A single global Grafana querying
both regions' backends is possible (one Grafana, cross-region datasources or
Mimir/centralized storage) but is more moving parts; per-region is the simpler,
cheaper default. Revisit if you want a single pane of glass across regions.

---

## 9. Validate further

What's been checked here: `hcl fmt` (clean), `hcl validate` (0 errors — all unit
wiring + dependencies resolve with mocks), and `tofu validate` on all local
modules. What that does **not** fully cover: the registry **ecs service**
module's input shapes — particularly `service_connect_configuration` (the
`service`/`client_alias` block) and the multi-target-group `load_balancer` on
Alloy. Before a real apply:

```bash
cd terragrunt && terragrunt hcl fmt
cd live/dev/us-west-2 && terragrunt run-all plan   # downloads modules; needs AWS creds
```

and re-pin every `?version=` / `version =` to the latest you trust. The cluster
module's Service Connect input is `cluster_service_connect_defaults` (a wrong
guess there was the one bug validation already caught).

---

## 10. Cost & teardown

- **Cost floor per region:** NAT gateway(s), the ALB + internal NLB, EFS, and 5
  always-on Fargate tasks. No RDS (Sonar dropped) keeps it lighter than Conduct.
  S3 (Loki/Tempo) is usage-priced and cheap. dev = single NAT + tiny tasks.
- **Teardown:** `terragrunt run-all destroy` per region. prod ALB/NLB have
  deletion protection on; disable to destroy. S3 buckets with data won't delete
  unless emptied (expected guardrail).

---

## 11. Design decisions

- **LGTM + Alloy only, no SonarQube:** production-traffic services go to AWS;
  build-quality tooling stays local. Also removes the need for RDS in this stack.
- **S3 for Loki/Tempo, EFS for Prometheus/Grafana:** match each component to the
  storage it's designed for; keep the log/trace backends stateless.
- **Baked config images:** the idiomatic ECS way to ship config; immutable +
  versioned. EFS-staged config is the documented alternative.
- **Service Connect for east-west discovery:** backends reachable by name with
  no internal ALBs; least moving parts.
- **Internal NLB for OTLP, public ALB for Grafana:** OTLP/gRPC wants raw TCP +
  client-IP preservation (NLB); the Grafana UI wants HTTPS + host routing (ALB).
- **Per-region stacks:** telemetry stays in-region; simplest multi-region model.
- **Managed alternatives** (Amazon Managed Prometheus/Grafana) are viable swaps
  if self-hosting Prometheus/Grafana on Fargate becomes a maintenance burden.
```
