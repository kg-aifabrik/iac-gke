# 11 — Multi-subdomain routing: three subdomains, two services, one gateway

This example shows how **one** public gateway can serve **many** subdomains
over HTTPS, and how the **URL path** decides which service answers. It runs as
case 14 of [`validate.sh`](../validate.sh).

Two small web services — `helloworld1` and `helloworld2` — sit behind the
cluster's shared external gateway. Three subdomains all reach the same
gateway; the path picks the service:

| URL | Answered by |
|---|---|
| `https://sd1.dev.arthos.app/h1` | helloworld1 |
| `https://sd2.dev.arthos.app/h1` | helloworld1 |
| `https://sd3.dev.arthos.app/h1` | helloworld1 |
| `https://sd1.dev.arthos.app/h2` | helloworld2 |
| `https://sd2.dev.arthos.app/h2` | helloworld2 |
| `https://sd3.dev.arthos.app/h2` | helloworld2 |

Each response tells you exactly which service answered and which subdomain the
request came through — the nginx in each service echoes its own name and the
Host header it received:

```
$ curl https://sd2.dev.arthos.app/h1
service=helloworld1 host=sd2.dev.arthos.app path=/h1
```

So you can verify the routing with your own eyes: change the subdomain and
`host=` changes; change the path and `service=` changes.

## The moving parts

Only four kinds of things are involved:

1. **Two Deployments + Services** (`helloworld1`, `helloworld2`) — ordinary
   nginx pods in the `public-services` namespace, hardened to the repo's
   baseline (non-root, read-only filesystem, no Linux capabilities).
2. **One HTTPRoute** — a Kubernetes Gateway API object that says: *"on the
   external gateway, I claim hostnames sd1/sd2/sd3.dev.arthos.app; send `/h1`
   to helloworld1 and `/h2` to helloworld2."* This is the only routing config
   the example owns.
3. **The shared external gateway** — already provided by the platform (one per
   cluster). It owns the public IP, terminates TLS, and redirects HTTP to
   HTTPS. Many examples/apps attach routes to it; nobody creates their own
   load balancer.
4. **Three managed TLS certificates** — one per subdomain, publicly trusted,
   issued and renewed by Google. Created by Terraform from one line of config.

Everything is in [`ingress.yaml`](ingress.yaml) except the certificates and
DNS, which come from platform configuration (next section).

## How it is configured, step by step

### Step 1 — declare the hostnames (one line of config)

The only input is the cluster's hostname list in
[`config/clusters.yaml`](../../config/clusters.yaml):

```yaml
external_hostnames: [sd1.dev.arthos.app, sd2.dev.arthos.app, sd3.dev.arthos.app]
```

Adding a subdomain to a cluster **is** adding an entry here
([ADR-0005](../../docs/adr/0005-multi-host-gateways-no-wildcards.md): "adding
an app is adding an entry"). The cluster-factory then regenerates the
Terraform root, and `terraform apply` does the rest.

### Step 2 — Terraform provisions the Google pieces (per hostname)

For **each** hostname in the list, the
[`gke-gateway` module](../../terraform/modules/gke-gateway/main.tf) creates:

- a **DNS authorization** — proof to Google's certificate authority that we
  control the name (it emits one validation CNAME record);
- a **managed certificate** — publicly trusted, auto-renewed, for that one
  hostname;
- a **certificate map entry** — plugs the certificate into the gateway's
  single certificate map, so the load balancer can pick the right cert for
  each hostname during the TLS handshake (this selection-by-hostname is
  called Server Name Indication, SNI);
- two **DNS records** in the Cloud DNS zone `dev.arthos.app`: the hostname's
  `A` record pointing at the gateway's public IP, and the validation CNAME
  from the first bullet. (Automated because dev runs `manage_public_dns:
  true`, [ADR-0006](../../docs/adr/0006-cloud-dns-private-zone-public-opt-in.md).)

Nothing gateway-side changes per hostname — the gateway, its reserved global
IP (`136.68.48.242`), SSL policy, and Cloud Armor policy are shared and
already exist.

### Step 3 — deploy the apps and the route

[`ingress.yaml`](ingress.yaml) contains the two services and the one
HTTPRoute. The route's core is easy to read:

```yaml
hostnames:
  - sd1.dev.arthos.app
  - sd2.dev.arthos.app
  - sd3.dev.arthos.app
rules:
  - matches: [{ path: { type: PathPrefix, value: /h1 } }]
    backendRefs: [{ name: helloworld1, port: 80 }]
  - matches: [{ path: { type: PathPrefix, value: /h2 } }]
    backendRefs: [{ name: helloworld2, port: 80 }]
```

One guardrail to know about: the gateway only accepts routes from namespaces
labelled `ingress=external` — `public-services` carries that label, so the
attachment is allowed.

### Step 4 — GKE programs the load balancer for you

After the route is applied, the GKE Gateway controller notices it and
translates it into Google load-balancer configuration: host rules for the
three subdomains, path rules to the two backend services, and Network
Endpoint Groups (NEGs) that point straight at the pod IPs (only pods passing
their readiness probe get traffic). This programming takes a few minutes the
first time; no human touches the load balancer.

## What lives OUTSIDE Google — your DNS provider

Exactly **one thing**, and it is one-time (not per hostname): the `NS`
delegation that hands the `dev.arthos.app` subdomain to the Cloud DNS zone.
At the `arthos.app` DNS provider (GoDaddy), four records with host `dev`,
type `NS`, pointing at the zone's name servers
(`terraform output public_zone_name_servers`):

```
ns-cloud-b1.googledomains.com.
ns-cloud-b2.googledomains.com.
ns-cloud-b3.googledomains.com.
ns-cloud-b4.googledomains.com.
```

Once that delegation exists, **no** DNS work is ever needed at the provider
again — every new hostname's records land in the delegated zone
automatically, and Google validates + issues its certificate on its own.

> ⚠️ **After a cluster teardown → rebuild**, the re-created zone usually gets
> a *different* `ns-cloud-*` name-server set, and the provider's NS records
> silently go stale — certificates then sit in `PROVISIONING` forever. Check
> `dig NS dev.arthos.app` against the terraform output. See
> [runbook 02](../../docs/runbooks/02-cluster-bringup.md). (We hit exactly
> this during bring-up — see Troubleshooting below.)

## Why three certificates instead of one?

You might expect one certificate listing all three subdomains. This platform
deliberately issues **one certificate per hostname** and lets the load
balancer pick the right one by SNI at handshake time (ADR-0005). The
trade-off: hostnames can be added and removed independently (no shared
certificate to reissue), and no certificate ever reveals names it does not
serve. A client connecting to `sd2` sees a certificate for exactly
`sd2.dev.arthos.app` — see the live results below.

## Diagrams

**Configuration** — how the pieces are provisioned and wired
([editable source](configuration.excalidraw)):

![Configuration](configuration.png)

**Traffic flow** — what happens between typing the URL and getting the
response ([editable source](traffic-flow.excalidraw)):

![Traffic flow](traffic-flow.png)

In words, a request to `https://sd2.dev.arthos.app/h1` goes through six steps:

1. **DNS** — the provider's NS delegation leads to the Cloud DNS zone, whose
   `A` record answers with the gateway's global anycast IP.
2. **TLS handshake** — Google's edge sees the requested hostname (SNI),
   looks it up in the certificate map, and serves `sd2`'s own certificate.
   (Plain `http://` on port 80 is answered with a `301` redirect to HTTPS.)
3. **Cloud Armor** — the security policy checks the request.
4. **URL map** — host `sd2.dev.arthos.app` + path `/h1` → backend service
   `helloworld1`. This is the HTTPRoute, translated.
5. **NEG** — the request goes straight to a ready pod's IP.
6. **The pod answers** — nginx echoes `service=helloworld1
   host=sd2.dev.arthos.app path=/h1`, which travels back to the client.

## Run it yourself

```bash
# One-time per shell: terraform reads its state from GCS, which needs
# application-default credentials (ADC):
gcloud auth application-default login

examples/validate.sh --only multi-subdomain           # deploy, assert all 6 URLs, clean up
examples/validate.sh --only multi-subdomain --keep    # same, but leave the URLs live
examples/validate.sh --cleanup --only multi-subdomain # tear down a --keep run
```

What the check does: deploys `ingress.yaml`, waits for both services to be
ready, then curls **all six** host+path combinations with the certificate
fully verified (no `-k`) and asserts each body names the right service and
subdomain. On the first run it waits up to ~6 minutes for the load balancer
to finish programming.

## Live results (dev-fop, validated 2026-07-06)

Captured from the real environment after the NS delegation was in place.

**The validation case, standalone:**

```
[PASS] multi-subdomain — all 6 host+path combinations served: /h1->helloworld1,
/h2->helloworld2 on sd1.dev.arthos.app sd2.dev.arthos.app sd3.dev.arthos.app,
each echoing its own subdomain, per-host certs valid
```

**All six URLs from the public internet** (plain curl, no `--resolve`, full
certificate verification):

```
$ curl https://sd1.dev.arthos.app/h1
service=helloworld1 host=sd1.dev.arthos.app path=/h1
$ curl https://sd1.dev.arthos.app/h2
service=helloworld2 host=sd1.dev.arthos.app path=/h2
$ curl https://sd2.dev.arthos.app/h1
service=helloworld1 host=sd2.dev.arthos.app path=/h1
$ curl https://sd2.dev.arthos.app/h2
service=helloworld2 host=sd2.dev.arthos.app path=/h2
$ curl https://sd3.dev.arthos.app/h1
service=helloworld1 host=sd3.dev.arthos.app path=/h1
$ curl https://sd3.dev.arthos.app/h2
service=helloworld2 host=sd3.dev.arthos.app path=/h2
```

**Per-host certificate, as a client sees it** (note the Subject and the single
Subject Alternative Name — this is the per-hostname certificate design):

```
$ echo | openssl s_client -connect sd1.dev.arthos.app:443 -servername sd1.dev.arthos.app \
    | openssl x509 -noout -text | grep -E "Subject:|Issuer:|DNS:|Not"
Issuer: C=US, O=Google Trust Services, CN=WR3
Not Before: Jul  6 21:53:32 2026 GMT
Not After : Oct  4 22:49:27 2026 GMT
Subject: CN=sd1.dev.arthos.app
DNS:sd1.dev.arthos.app
```

**Certificate Manager** (all three issued and auto-renewing):

```
external-cert-sd1-dev-arthos-app  ACTIVE
external-cert-sd2-dev-arthos-app  ACTIVE
external-cert-sd3-dev-arthos-app  ACTIVE
```

**DNS and the HTTP→HTTPS redirect:**

```
$ dig +short NS dev.arthos.app
ns-cloud-b1.googledomains.com.    (…b2, b3, b4)
$ dig +short sd1.dev.arthos.app
136.68.48.242
$ curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://sd1.dev.arthos.app/h1
301 -> https://sd1.dev.arthos.app:443/h1
```

## Troubleshooting — failures we actually hit during bring-up

| Symptom | What it means | Fix |
|---|---|---|
| `curl: (35) … SSL_ERROR_SYSCALL` | The load balancer has **no certificate to serve** for that hostname — the cert is still `PROVISIONING`. | Wait for `ACTIVE`; if it never comes, check the NS delegation (next row). |
| Certificates stuck in `PROVISIONING` / domain `AUTHORIZING` | Google validates the DNS-authorization CNAME over **public** DNS, and public resolution is broken — usually a stale NS delegation after a teardown→rebuild (`dig NS dev.arthos.app` returns `SERVFAIL` or the wrong `ns-cloud-*` set). | Update the provider's NS records to match `terraform output public_zone_name_servers`. |
| `404` with body `fault filter abort` on a URL that just worked | Nothing is deployed behind the hostname — a successful validation run **auto-cleans** the example; the body text is the load balancer's proxy layer mid-deprogramming. TLS still verifies. | Redeploy with `--only multi-subdomain --keep` to keep it live. |
| `error: could not resolve REGISTRY_PROXY …` from validate.sh | Terraform could not read its GCS state: your application-default credentials are missing/expired (they are separate from `gcloud auth login`). | `gcloud auth application-default login`, or `export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)` for a ~1 h session. |
