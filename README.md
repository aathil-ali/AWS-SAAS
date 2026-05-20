
# Architecture Document
## Production-Grade B2C SaaS on AWS

---

## Guiding Principles

Before the components — four principles drive every decision in this architecture:

1. **Start small, scale automatically** — no over-provisioning now. Resources are small but the architecture supports 1M users without redesign.
2. **Cost optimization first** — B2C means thin margins. Every component has a cheaper staging variant and scales to zero where possible.
3. **No single point of failure** — every critical component has a failover path at pod, node, AZ, and region level.
4. **Security by default** — encrypted at rest and in transit everywhere, least-privilege IAM, no static credentials.

---

## 1. AWS Organization & Account Structure

### What it is
AWS Organizations lets you group multiple AWS accounts under one root (management) account. Think of it like a parent company owning subsidiaries — one bill, one place to set rules, but separate environments.

### Structure
```
Management Account   ← billing, org policies, IAM Identity Center. No workloads run here.
├── Staging Account  ← developers work freely, break things safely
└── Production Account ← locked down, only pipelines can deploy
```

### Why separate accounts instead of separate VPCs?
A common mistake is using one account with two VPCs. Separate accounts give you:
- **Blast radius isolation** — a developer mistake in staging cannot touch production. Different account = different AWS API boundary.
- **Separate billing** — you can see exactly what staging costs vs production.
- **Separate IAM** — a staging IAM role literally cannot be used in production, even accidentally.
- **Compliance** — auditors want production isolated. Separate accounts is the AWS-recommended way.

### IAM Identity Center (SSO)
Single sign-on across both accounts. Your team logs in once and gets role-based access to each account. Three roles:

| Role | Staging | Production |
|---|---|---|
| Developer | Full admin | Read-only (logs, metrics only) |
| DevOps / Lead | Full admin | Deploy via pipeline + CloudWatch |
| Admin | Full admin | Full admin |

No one SSHes directly into production servers. All production changes go through the pipeline with a manual approval gate. This is non-negotiable for production grade.

---

## 2. Networking — VPC

### What it is
A Virtual Private Cloud is your private isolated network inside AWS. Everything runs inside it. Nothing is exposed to the internet unless you explicitly open it.

### Why us-east-1?
Most AWS services, lowest cost, highest availability, most documentation written against it. Both accounts in the same region — DR replica in us-west-2 (covered in disaster recovery section).

### Subnet design
```
VPC: 10.0.0.0/16

Public subnets (internet-facing):
  ├── 10.0.1.0/24  (us-east-1a)
  ├── 10.0.2.0/24  (us-east-1b)
  └── 10.0.3.0/24  (us-east-1c)   ← production only

Private subnets (no direct internet access):
  ├── 10.0.10.0/24 (us-east-1a)
  ├── 10.0.11.0/24 (us-east-1b)
  └── 10.0.12.0/24 (us-east-1c)   ← production only
```

**Public subnets** hold: Load balancers, NAT Gateways. These can receive traffic from the internet.

**Private subnets** hold: EKS nodes, RDS, ElastiCache, everything else. These can reach the internet via NAT Gateway (for outbound calls like pulling npm packages), but the internet cannot reach them directly. Even if someone finds your database host, there is no route in.

### NAT Gateway
Allows private subnet resources (your pods) to make outbound internet calls (pull images, call external APIs) without being publicly accessible. Think of it as a one-way door — outbound only.

**Cost optimization:**
- Staging: 1 shared NAT Gateway (~$32/month)
- Production: 1 per AZ (3 total) — if an AZ fails, other AZs still have their own outbound path

### VPC Endpoints
Without these, traffic from your pods to AWS services (S3, DynamoDB, ECR, Secrets Manager) exits your VPC, travels over the public internet, then comes back in. VPC Endpoints create a private route that stays inside the AWS network entirely.

**Why this matters:**
- Security — data never leaves the AWS backbone
- Cost — NAT Gateway charges per GB of data. At scale, S3 and ECR traffic through NAT Gateway is expensive. VPC Endpoints are flat hourly cost or free (S3 and DynamoDB endpoints are free gateway type).
- Speed — lower latency

---

## 3. Compute — Amazon EKS (Kubernetes)

### What is Kubernetes?
Kubernetes is a container orchestration system. You package your Node.js app into a Docker container, and Kubernetes decides which server to run it on, restarts it if it crashes, scales it up under load, and rolls out new versions without downtime.

### Why EKS (managed Kubernetes) instead of running Kubernetes yourself?
Running a Kubernetes control plane (the "master" that coordinates everything) is complex, requires 3+ servers for high availability, and needs constant patching. EKS is AWS's managed version — AWS runs the control plane for you ($0.10/hour). You only manage the worker nodes (EC2 instances where your pods actually run).

### Node Groups (EC2 Auto Scaling Groups)
Worker nodes are EC2 instances grouped into Auto Scaling Groups — AWS automatically adds or removes instances based on demand.

Two node groups:

**System node group** — runs Kubernetes internals (DNS, monitoring agents, Karpenter). Always on, On-Demand instances (Spot is too risky for system components).

**App node group** — runs your Node.js pods. Mix of On-Demand and Spot instances.

Starting sizes:
```
Staging:     1x t3.small system,  1x t3.medium app
Production:  2x t3.medium system, 2x t3.large app (min)
```

### Why Spot Instances?
Spot instances are spare AWS capacity offered at 60-80% discount. The catch: AWS can reclaim them with 2 minutes notice. Kubernetes (via Karpenter) handles this gracefully — it drains pods off a Spot instance before it's terminated and reschedules them elsewhere. For stateless web apps, this is safe and dramatically cuts costs.

### Karpenter — Node Autoscaler
When your pods can't be scheduled (not enough capacity), Karpenter automatically launches new EC2 nodes. When nodes are underutilized, it consolidates pods and terminates empty nodes.

Why Karpenter over the older Cluster Autoscaler?
- Smarter bin-packing (fits more pods per node, wastes less money)
- Handles Spot interruptions proactively
- Launches the right instance type for each workload automatically
- Faster scaling decisions

### HPA — Horizontal Pod Autoscaler
Karpenter scales nodes (EC2 instances). HPA scales pods (your app containers) first. When CPU hits 70%, HPA adds more pods. When pods can't fit on existing nodes, Karpenter adds a new node. They work as a team.

### Pod Resilience Settings

**Liveness probe** — Kubernetes hits your `/health` endpoint every 10 seconds. If it fails 3 times, Kubernetes kills the pod and starts a new one. Without this, a hung or deadlocked process sits doing nothing forever.

**Readiness probe** — Before Kubernetes sends traffic to a new pod, it checks `/ready`. The pod must pass this check before being included in the load balancer. Without this, you get errors during deployments as traffic hits pods that haven't finished starting up.

**Pod Disruption Budget (PDB)** — sets `minAvailable: 1`, meaning Kubernetes will never take down all your pods at once (during node upgrades, scaling events, etc.). At least one pod stays running.

**Pod anti-affinity** — instructs Kubernetes to spread your pods across different Availability Zones. If us-east-1b goes down, you still have pods in 1a and 1c.

**Resource limits** — every pod has CPU and memory limits. Without this, one memory-leaking pod can starve other pods on the same node.

---

## 4. Authentication — AWS Cognito

### What it is
Cognito is AWS's managed user authentication service. It handles: sign-up, sign-in, email verification, forgot password, JWT token issuance, and user management. You don't write any of this code.

### Why Cognito for B2C?
**Cost:** Free for the first 50,000 Monthly Active Users. At zero users today, it costs $0. It scales automatically.

**Integration:** Cognito tokens (JWTs) are natively understood by API Gateway — no custom auth middleware needed. API Gateway validates the token before your backend ever sees the request.

**Email flows built in:** Password reset emails, verification emails — Cognito handles these via SES (covered below). Zero backend code.

### User Pools vs Identity Pools
We use **User Pools** — this is the directory of your users (email, password, profile). Identity Pools are for giving AWS resource access to end users, which we don't need.

### Three Application Roles

| Role | Who | What they can do |
|---|---|---|
| `super-admin` | Platform team | Everything — user management, billing, feature flags, all data |
| `admin` | Internal team | Content and user management, no billing |
| `user` | End customers | Standard app access |

Implemented as **Cognito Groups**. When a user logs in, their JWT token includes a claim: `"cognito:groups": ["admin"]`. API Gateway passes this to your backend, which enforces permissions. No separate RBAC database needed.

### MFA Policy
- `super-admin` and `admin` groups: MFA mandatory (TOTP authenticator app)
- `user` group: MFA optional — you never want to add friction for B2C sign-up

---

## 5. API Layer — API Gateway + ALB

### API Gateway (HTTP API)
The front door for all backend API traffic. Why it sits in front of EKS rather than exposing EKS directly:

- **Auth enforcement** — Cognito authorizer validates JWTs before requests reach your backend. Unauthenticated requests are rejected at the edge, saving your backend from processing them.
- **Throttling** — rate limits per route. Prevents a single user (or attacker) from overwhelming your backend.
- **Cost** — HTTP API (not REST API) is the cheaper variant. ~$1 per million requests.

### Application Load Balancer (ALB)
Sits inside the VPC, routes traffic from API Gateway (via VPC Link) to Kubernetes pods. The ALB talks to the Kubernetes Ingress controller, which knows which pods are healthy and ready.

**VPC Link** is the private tunnel between API Gateway (public) and ALB (private). Traffic never crosses the public internet between these two.

### Traffic Flow
```
Internet → CloudFront → API Gateway → VPC Link → ALB → Nginx Ingress → Pod
```

---

## 6. Frontend Delivery — CloudFront + S3

### S3 (Frontend Hosting)
Your React app is a static build (`npm run build`) — HTML, CSS, JavaScript files. These get uploaded to an S3 bucket. S3 is object storage that can serve files over HTTP. There's no server running, no compute to manage, essentially zero cost at low traffic.

### CloudFront (CDN)
CloudFront is AWS's Content Delivery Network. It caches your static files at 400+ edge locations worldwide. When a user in London hits your app, they get the files from a London edge server, not from us-east-1. This makes the app feel fast regardless of where users are.

**Why CloudFront in front of API Gateway too?**
- Caches API responses where possible (e.g. public product listings)
- Single domain for both frontend and API — avoids CORS complexity
- WAF sits here, inspecting all traffic (covered in security section)

### Route53
AWS's DNS service. Maps your domain to CloudFront. Also handles health checks and automatic failover to the DR region if the primary goes down. Domain is not set up yet but the Route53 hosted zone is provisioned from day one, ready.

---

## 7. Object Storage — S3 (User Uploads)

This is a separate S3 bucket from the frontend bucket. For user-generated content — profile pictures, documents, media files.

### Why Direct Upload (Pre-signed URLs)?
The wrong way: `User → uploads file → your Node.js pod → pod streams to S3`. At 1M users uploading files, your pods become bottlenecked handling file bytes — CPU, memory, bandwidth all spike.

The right way:
```
User → asks your API for upload permission
API  → generates a pre-signed S3 URL (valid 5 minutes)
API  → returns URL to user
User → uploads directly to S3 (bypasses your servers entirely)
S3   → serves files back via CloudFront
```

Your pods only handle a tiny metadata request, never touch the file bytes. This is how Dropbox, Airbnb, and every large-scale app handles uploads.

### S3 Bucket Settings
- **Versioning on** — if a user overwrites a file accidentally, you can recover the previous version. Also required for GDPR right-to-be-forgotten (you must be able to delete all versions).
- **Public access blocked** — files are only accessible via pre-signed URLs or CloudFront. No direct S3 URLs.
- **SSE-KMS encryption** — files encrypted at rest with your own KMS key.
- **Lifecycle policy** — move files to S3 Infrequent Access after 90 days (cheaper), Glacier after 1 year (very cheap long-term archive).
- **Cross-region replication** → us-west-2 for disaster recovery.

### Other S3 Buckets
- `backups` — RDS snapshots, DynamoDB exports land here
- `logs-archive` — CloudWatch logs older than 90 days archived here cheaply
- `terraform-state` — Terraform's state files stored here (one bucket per account)

---

## 8. Databases

### Aurora PostgreSQL Serverless v2 — Relational Data

**What it's for:** Structured, relational data with relationships. Users, subscriptions, orders, anything where you write SQL queries with JOINs.

**Why Aurora over standard RDS PostgreSQL?**
Aurora is AWS's reimplementation of PostgreSQL with a distributed storage layer. Key advantages:
- Storage auto-grows in 10GB increments up to 128TB — you never provision storage
- Up to 5x faster than standard PostgreSQL (AWS engineering in the storage layer)
- Serverless v2 scales compute up and down automatically in 0.5 ACU increments — at 0 users, it idles near-zero, saving money

**Staging:** Single instance, scales 0.5–4 ACUs, single AZ. Cheaper, acceptable for non-production.

**Production:** 1 writer + 1 reader replica, multi-AZ. If the writer instance fails, Aurora automatically promotes the reader to writer in ~30 seconds. No manual intervention.

**Point-in-Time Recovery (PITR):** You can restore the database to any second within the last 35 days. If someone accidentally deletes a table, you can restore from 5 minutes before it happened.

### RDS Proxy — Connection Pooling

**The problem:** Each Node.js pod opens database connections. At 100 pods, that's potentially 100+ connections to Aurora. Aurora has a connection limit (based on instance size). At scale with hundreds of pods, you exhaust the connection limit and the database starts refusing connections — instant outage.

**RDS Proxy** sits between your pods and Aurora. Pods connect to the proxy (thousands of connections supported). Proxy maintains a small pool of real connections to Aurora (10-20). It multiplexes pod connections onto real connections — 100 pods share 10 real database connections.

**Additional benefit:** On Aurora failover (writer dies, reader promoted), RDS Proxy handles the reconnection transparently. Pods see a brief pause, not an error. Failover time drops from 60 seconds to ~5 seconds.

### DynamoDB — High-Throughput NoSQL

**What it's for:** Data that doesn't need complex queries or relationships, but needs to handle massive read/write throughput. Sessions, events, activity feeds, feature flags, rate limiting counters.

**Why DynamoDB alongside RDS?**
Aurora is great but has a ceiling — you scale it by upgrading instance size (vertical scaling), which has limits and causes brief downtime. DynamoDB scales horizontally to any throughput with zero downtime, automatically.

At 1M users, you might have 10M session reads per day. That's fine for DynamoDB, expensive and potentially overwhelming for Aurora.

**On-demand billing mode:** Pay per request. At 0 users: $0. At 1M users: scales automatically. No capacity planning needed.

**Key tables:**
- `sessions` — user sessions with TTL (auto-expire after inactivity, no cleanup needed)
- `user_events` — activity feed, analytics events
- `feature_flags` — per-user feature toggles (roll out features to % of users)
- `api_rate_limits` — track API usage per user for throttling

**PITR enabled** — same 35-day restore window as Aurora.

### ElastiCache Redis — Cache Layer

**What it's for:** Data that's expensive to compute or query but accessed frequently. Hot data that doesn't need to live in the database on every request.

**Use cases:**
- Session data (faster than DynamoDB for sub-millisecond reads)
- Hot database query results (top products, user profile, cached 5 minutes)
- Rate limiting counters (increment a counter per user per minute — Redis atomic operations)
- Real-time features (leaderboards, online user counts)

**Why Redis over Memcached?** Redis supports data structures (sorted sets for leaderboards, lists for queues), persistence, and pub/sub. Memcached is simpler but Redis is strictly more capable.

**Staging:** 1 node, `cache.t3.micro`. If it dies, app falls back to database — acceptable for staging.

**Production:** Primary + replica across two AZs. Automatic failover. Redis is cache — losing it doesn't lose data permanently, but it causes a stampede of database queries if it dies without a replica (cache miss storm).

---

## 9. Async Processing — SQS + SES

### Why Async?

In a synchronous architecture, everything that happens during an API request must complete before the response is sent. Sending a welcome email takes 200ms. Processing an uploaded image takes 2 seconds. At 1M users, these blocking operations kill your API response times.

Async pattern: API receives request → enqueues a message → immediately returns 200 → background worker processes the message separately. The user gets a response in 50ms. The email sends 2 seconds later. They never notice.

### SQS (Simple Queue Service) — Message Queue

**What it is:** A managed queue where your API puts messages ("send welcome email to user X") and worker pods consume and process them.

**Dead Letter Queue (DLQ):** If a message fails to process 3 times (network error, bug, external API down), it goes to the DLQ. You can inspect, debug, and replay failed messages. Without a DLQ, failed messages are silently lost.

**Queues planned:**
- `email-queue` — welcome emails, notifications, billing receipts
- `file-processing-queue` — resize/compress images after user upload
- `billing-events-queue` — process subscription events from payment provider
- `dead-letter-queue` — failed messages from all above queues

### SES (Simple Email Service) — Email Sending

**What it is:** AWS's email sending service. Handles deliverability, bounce handling, complaint management.

**Why SES specifically?**
- Cognito requires SES to send verification and password reset emails
- Much cheaper than SendGrid/Mailgun at scale ($0.10 per 1,000 emails vs $14.95+/month)
- Bounce and complaint handling: if users mark your emails as spam, SES notifies you via SNS so you can remove them from your list (required to maintain good deliverability)

**Important:** SES starts in "sandbox mode" — you can only send to verified email addresses. You must request production access before launch. Takes 24-48 hours to be approved. Do this early.

---

## 10. CI/CD — AWS CodePipeline + CodeBuild

### Why CodePipeline over GitHub Actions?
You asked for CodePipeline. The advantage in an AWS-native stack: CodePipeline integrates directly with ECR, EKS, and IAM without managing secrets in GitHub. The pipeline itself runs with an IAM role, not stored credentials.

### Pipeline Stages

**Source** — CodeStar Connection watches your GitHub repo. On merge to `main`, the pipeline triggers automatically. This is a webhook, not polling.

**Build (CodeBuild)** — A container spins up and runs:
1. Install dependencies, run tests
2. Run Trivy (security scanner) — scans for known vulnerabilities in your Docker image. Pipeline fails if critical CVEs found.
3. Build Docker image
4. Push to ECR (staging account's registry)

**Deploy to Staging** — Helm upgrade on EKS staging cluster. Kubernetes rolls out new pods one at a time (rolling update), checking readiness probes before proceeding. If pods fail to start, Helm automatically rolls back.

**Manual Approval Gate** — Pipeline pauses. SNS sends an email to the DevOps lead. Someone reviews staging, clicks Approve in the AWS console. Without approval, the pipeline stops here. This ensures no code reaches production without a human sign-off.

**Promote Image** — The same Docker image (not rebuilt) is re-tagged and pushed to the production ECR. Same image tested in staging is what deploys to production. No surprises from rebuilding.

**Deploy to Production** — Helm upgrade on EKS production cluster. Same rolling update process, but production has a PDB ensuring minimum replicas stay up.

### ECR Lifecycle Policies

ECR stores your Docker images. Without cleanup rules, every build adds a new image permanently. 500 builds = 500 images = money wasted.

Lifecycle policy: keep last 10 tagged images, delete untagged images after 1 day. Enforced automatically by ECR.

### Database Migrations

Before each deploy, a Kubernetes Job runs first: pulls the new image, runs `node migrate.js` (or Flyway/Liquibase), completes. Only then do pods roll over. If the migration fails, the pipeline stops — pods stay on the old version with the old schema.

**Golden rule:** migrations must always be backwards-compatible. The old code must work with the new schema during the rollout window (when old and new pods run simultaneously).

---

## 11. Security

### AWS WAF (Web Application Firewall)

Sits on CloudFront, inspects all incoming traffic before it reaches your application. Protects against:
- SQL injection attempts
- XSS (cross-site scripting)
- Rate limiting per IP (blocks scrapers and brute-force attacks)
- Bot detection
- OWASP Top 10 managed rule set (AWS maintains these rules, you just enable them)

### AWS CloudTrail — Audit Log

Every API call made to AWS — by humans, by pipelines, by services — is logged to CloudTrail. Who created a resource, who deleted it, who changed a security group, when, from which IP.

This is non-negotiable for production because:
- **Security incident response** — if something goes wrong, CloudTrail tells you exactly what happened and who did it
- **Compliance** — SOC2, ISO27001, GDPR all require audit logs
- **Debugging** — "why did this resource change?" is answered by CloudTrail

Logs go to an S3 bucket in the management account, encrypted. Even admins cannot delete these logs (S3 Object Lock).

Alerts set up for:
- Root account login → immediate page
- IAM policy changed in production → alert
- Security group opened to `0.0.0.0/0` → alert
- CloudTrail disabled (by anyone) → alert

### AWS GuardDuty — Threat Detection

Constantly analyzes CloudTrail logs, VPC Flow Logs, and DNS queries using machine learning to detect threats. Examples of what it catches:
- An EC2 instance suddenly making requests to a known crypto-mining domain
- API calls from an IP that has never accessed your account before
- Unusual data exfiltration patterns
- Credential theft attempts

Cost: ~$1-3/month at low traffic. Extremely cheap insurance. Findings go to Security Hub.

### AWS Security Hub

Aggregates security findings from GuardDuty, AWS Inspector, and AWS Config into one dashboard. Also runs the CIS AWS Foundations Benchmark — a checklist of ~100 security best practices — against your accounts automatically. You get a compliance score and a list of what to fix.

### AWS Config

Tracks configuration changes to every AWS resource. Enables compliance rules like:
- "RDS must have encryption enabled" — non-compliant instance triggers an alert
- "S3 buckets must have public access blocked"
- "Security groups cannot be open to `0.0.0.0/0` on port 22"

### AWS Secrets Manager

All credentials (database passwords, API keys, third-party secrets) stored in Secrets Manager, never in environment variables or code.

**Auto-rotation:** Secrets Manager rotates RDS passwords automatically every 30 days. It generates a new password, updates it in RDS, updates the secret — zero downtime because RDS Proxy handles the rotation gracefully. Your pods never know the password changed.

### KMS (Key Management Service)

Encryption keys for all data at rest: RDS, S3, EBS (EC2 node disks), DynamoDB, ElastiCache. KMS manages the key lifecycle — rotation, access control, audit logging of every use of the key.

### IRSA (IAM Roles for Service Accounts)

Your Node.js pods need to call AWS services (write to S3, read from Secrets Manager, write to DynamoDB). The wrong way: generate an IAM user, put the access key in an environment variable. If that pod is compromised, the key is exposed.

IRSA gives each Kubernetes pod its own IAM role with exactly the permissions it needs. No static credentials. The pod gets temporary tokens that expire automatically. Least-privilege by design.

### Kubernetes Network Policies

By default, any pod can talk to any other pod in the cluster. Network Policies restrict this:
- Backend pods can reach RDS, DynamoDB, Redis
- Backend pods cannot reach other backend pods directly
- No pod can make arbitrary outbound calls to the internet (only specific external APIs via egress rules)
- Monitoring pods can read from everything but cannot write

### CloudFront Security Headers

HTTP response headers that instruct browsers on security behavior:
- `Strict-Transport-Security` — browser must use HTTPS, never HTTP, for this domain
- `X-Frame-Options` — prevents your site from being embedded in an iframe on another domain (clickjacking prevention)
- `Content-Security-Policy` — controls which domains can load scripts, images, fonts (XSS mitigation)
- `X-Content-Type-Options` — prevents browsers from guessing file types (MIME sniffing attacks)

One Terraform resource, significant security improvement, zero cost.

### SCP Guardrails (Service Control Policies)

Organization-level policies that override even admin permissions. The safety net that cannot be bypassed:
- Cannot disable CloudTrail — ever, by anyone
- Cannot disable GuardDuty
- Cannot leave the AWS Organization
- Resources can only be created in `us-east-1` and `us-west-2` (prevents accidental resources in other regions)
- Cannot create IAM users (everyone must use SSO)
- Cannot make S3 buckets public

These apply to every account, including production admins. Even if someone's credentials are compromised, they cannot disable security controls.

---

## 12. Observability

### Fluent Bit → CloudWatch Logs

Fluent Bit runs as a DaemonSet — one pod on every node, automatically. It collects all container logs and ships them to CloudWatch Log Groups. Your application just writes to stdout (standard output), as every 12-factor app should. Fluent Bit handles the rest.

Log retention: 7 days (staging), 90 days (production), then archived to S3.

### CloudWatch Container Insights

Provides metrics for every EKS node and pod: CPU, memory, network, disk. Dashboards and alarms built on top. No configuration on your part — enable one EKS add-on and it works.

### CloudWatch Alarms → SNS

Alarms on the metrics that matter:
- Node CPU > 80% for 5 minutes → alert
- Pod restart count > 3 in 10 minutes → alert (crash-looping pod)
- RDS CPU > 75% → alert
- API Gateway 5xx error rate > 1% → alert
- DynamoDB throttled requests > 0 → alert (means traffic exceeded capacity, data loss risk)

SNS (Simple Notification Service) routes alerts to email and PagerDuty/OpsGenie for on-call paging.

### AWS X-Ray — Distributed Tracing

Where CloudWatch Logs tell you what happened, X-Ray tells you how long it took and where time was spent. A request comes in, X-Ray traces it through: API Gateway → Node.js pod → RDS query → DynamoDB call → response. You see exactly where the bottleneck is.

Critical for diagnosing performance issues at scale.

### CloudWatch Synthetics — Proactive Monitoring

Runs a script every 1 minute that hits your `/health` endpoint, 24/7, even when no real users are using the app. If it fails 3 consecutive checks, you get an alert.

Without this: your monitoring only detects problems when real users are affected. With this: you know within 3 minutes, day or night.

### Sentry — Error Tracking

CloudWatch Logs contain every log line — thousands per hour. When something breaks, you'd need to search through thousands of lines to find the error. Sentry captures unhandled exceptions specifically, groups duplicates, shows a readable stack trace, tells you how many users were affected, and when it first started happening.

It answers "what is broken right now?" — CloudWatch answers "what happened in the last hour?". Both are necessary. Sentry has a generous free tier.

### On-Call Integration

CloudWatch Alarm → SNS → PagerDuty (or OpsGenie free tier). PagerDuty calls or texts the on-call engineer. If no acknowledgement in 10 minutes, escalates to the lead. Without this, alarms fire at 3am and sit in an email inbox until morning.

---

## 13. Disaster Recovery

### Failure at Every Level

**Pod fails** → Kubernetes restarts it automatically (liveness probe). Takes ~10 seconds.

**Node fails** → ASG detects unhealthy instance, terminates it, launches a replacement. Karpenter reschedules pods onto healthy nodes. Takes ~3 minutes.

**Availability Zone fails** (e.g. us-east-1b datacenter issue) → ALB stops routing to that AZ. Aurora fails over to replica in different AZ (~30 seconds). Pods reschedule to remaining AZs (anti-affinity already spread them across AZs). Expected downtime: < 2 minutes.

**Bad deployment** → readiness probe fails on new pods → Helm rollback triggered automatically → old pods stay running → users see no interruption.

**Region fails** (us-east-1 catastrophic outage) → Pilot Light DR activates.

### Pilot Light DR — us-west-2

Pilot Light means: data is always replicated to the DR region, but compute (EKS, EC2) is not running there. In a disaster you run Terraform to spin up the compute. Think of it like a pilot light on a furnace — the flame is tiny but it can ignite the full system quickly.

**Data replication (always running, low cost):**
- Aurora Global Database — replication lag < 1 second
- DynamoDB Global Tables — async replication
- S3 Cross-Region Replication — user uploads bucket mirrors to us-west-2
- ECR images — available in both regions

**Recovery procedure:**
1. Route53 health check detects primary CloudFront endpoint unhealthy
2. DNS automatically flips to DR CloudFront endpoint in us-west-2
3. Engineer runs Terraform in us-west-2 to provision EKS, ALB, services
4. Aurora Global DB replica promoted to primary (~1 minute)
5. App is live in us-west-2

**RTO** (Recovery Time Objective): < 1 hour
**RPO** (Recovery Point Objective): < 1 minute (Aurora Global DB lag)

---

## 14. Governance & Cost Management

### Resource Tagging

Every AWS resource gets mandatory tags:
```
Environment  = staging | production
ManagedBy    = terraform
Application  = my-app
Team         = platform
CostCenter   = engineering
```

Enforced via AWS Config rule (non-tagged resources trigger alerts) and Terraform `default_tags` on the provider (applies automatically to everything Terraform creates).

Without tags, your AWS bill is a list of mysterious charges. With tags, you can filter costs by environment, team, or service.

### AWS Budgets

- Staging account: alert at $200/month
- Production account: alert at $1,000/month
- Anomaly detection per service (if S3 costs 10x normal, alert immediately)

Without this, a misconfigured NAT Gateway or runaway logging can silently burn thousands before anyone notices.

### GDPR

For any B2C app with EU users, this is a legal requirement:
- **Right to erasure:** When a user deletes their account, all their data must be deleted — RDS rows, DynamoDB records, S3 objects (including all versions). This requires a designed deletion workflow in your backend from day one.
- **Data minimization:** Don't log PII (names, emails) in CloudWatch logs.
- **DynamoDB TTL:** Tables holding personal data have TTL fields to auto-expire.
- **90-day log retention:** Compliant for most regulations.

### EKS Upgrade Strategy

AWS releases new Kubernetes versions regularly and deprecates old ones (typically supported for 14 months). EKS gives you advance notice.

Process: upgrade staging first → test for 1 week → upgrade production on a low-traffic window. Node groups upgrade by launching new nodes (new K8s version), draining pods off old nodes, deleting old nodes. Zero-downtime with PDBs in place.

---

## 15. Repository Structure

```
my-app/
├── frontend/                   React app (boilerplate)
├── backend/                    Node.js API (boilerplate)
├── infra/
│   ├── bootstrap/              Run once: org accounts, S3 state bucket
│   ├── modules/                Reusable Terraform modules
│   │   ├── vpc/
│   │   ├── eks/
│   │   ├── rds/
│   │   ├── dynamodb/
│   │   ├── elasticache/
│   │   ├── s3/
│   │   ├── api-gateway/
│   │   ├── cloudfront/
│   │   ├── cognito/
│   │   ├── sqs/
│   │   ├── ses/
│   │   ├── codepipeline/
│   │   ├── security/           GuardDuty, Config, CloudTrail, SecurityHub
│   │   └── monitoring/
│   └── environments/
│       ├── staging/
│       └── production/
├── k8s/
│   ├── base/                   Helm chart (deployment, service, hpa, ingress, pdb)
│   └── overlays/
│       ├── staging/
│       └── production/
├── .buildspec/
│   ├── buildspec-build.yml
│   └── buildspec-deploy.yml
└── docs/
    └── runbooks/
        ├── rds-failover.md
        ├── restore-from-backup.md
        ├── rollback-deployment.md
        └── region-failover.md
```

---

