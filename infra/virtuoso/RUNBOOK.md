# Virtuoso staging runbook

> Phase 1 of the Neo4j → Virtuoso migration. Single-replica
> StatefulSet in the `gmr` namespace, NFS-backed storage, 2 GiB
> hard memory limit. When the new prod node arrives, bump the
> ConfigMap + StatefulSet limits + cgroup; nothing else changes.

## Prerequisites (one-shot, before any manifest applies)

1. **NFS export directories** on the NFS server `10.44.0.6`
   (matches the existing Neo4j PV pattern):
   ```
   sudo mkdir -p /srv/nfs/virtuoso-data /srv/nfs/virtuoso-backup
   sudo chown -R 1000:1000 /srv/nfs/virtuoso-data /srv/nfs/virtuoso-backup
   sudo chmod 0775 /srv/nfs/virtuoso-data /srv/nfs/virtuoso-backup
   sudo exportfs -ra
   showmount -e localhost   # verify both paths are exported
   ```
   The `1000:1000` ownership matches the Virtuoso container's
   default UID:GID.

2. **Vault secret** populated:
   ```
   vault kv put secret/gmr/virtuoso \
       VIRTUOSO_DBA_USER=dba \
       VIRTUOSO_DBA_PASSWORD="$(openssl rand -base64 32)"
   ```
   The VSO sync into `virtuoso-credentials` Secret happens
   automatically once `05-secret-dba.yaml` is applied.

## TLS posture

In-cluster traffic between ETL writers / consolidator / gmr-api
and Virtuoso is plain HTTP on port 8890. Matches the existing
data-tier pattern (Neo4j has linkerd-injection disabled too) — the
cluster network is treated as trusted, and no in-cluster TLS is
load-bearing for the data tier.

The vault-issuer's PKI role (`pki_int/sign/void42-internal`) only
permits `*.void42.internal` and `*.void42.net` SANs, not
`*.svc.cluster.local`. Trying to mint a cert for the cluster-DNS
name would just fail. If we ever want in-cluster TLS, the right
move is opting in to linkerd (the mesh handles mTLS itself);
that's a future call, not Phase 1 work.

Public traffic stays bastion-terminated: data.fontem.eu →
Scaleway nginx (TLS) → cluster NodePort 31457 → port 8890 (HTTP).

## Apply order

Files are numerically prefixed for sequencing. Apply in order;
each step waits on the previous.

### Image supply chain — one-shot before first apply

The StatefulSet + CronJob both pull
`contribute.void42.internal/golden/virtuoso-opensource-7:7.2.14`,
mirrored from upstream `openlink/virtuoso-opensource-7:7.2.14`.
The Kyverno `verify-image-signatures` policy (Enforce mode) and
`require-sbom-attestation` policy (Audit) both gate
`contribute.void42.internal/golden/*`, so before the first apply
the mirrored image must carry a cosign signature and a CycloneDX
SBOM attestation:

```
docker pull docker.io/openlink/virtuoso-opensource-7:7.2.14
docker tag  docker.io/openlink/virtuoso-opensource-7:7.2.14 \
            contribute.void42.internal/golden/virtuoso-opensource-7:7.2.14
docker push contribute.void42.internal/golden/virtuoso-opensource-7:7.2.14

# Cosign key lives in the devspaces ns secret `cosign-keys`
kubectl get secret -n devspaces cosign-keys -o jsonpath='{.data.cosign\.key}' \
    | base64 -d > /tmp/cosign.key
COSIGN_PASSWORD="" cosign sign --key /tmp/cosign.key --yes \
    contribute.void42.internal/golden/virtuoso-opensource-7:7.2.14

syft contribute.void42.internal/golden/virtuoso-opensource-7:7.2.14 \
    -o cyclonedx-json=/tmp/sbom.cdx.json
COSIGN_PASSWORD="" cosign attest --key /tmp/cosign.key --type cyclonedx \
    --predicate /tmp/sbom.cdx.json --yes \
    contribute.void42.internal/golden/virtuoso-opensource-7:7.2.14
rm /tmp/cosign.key
```

### Manifests

```
kubectl apply -f 01-pv-data.yaml
kubectl apply -f 02-pv-backup.yaml
kubectl apply -f 03-pvcs.yaml
kubectl apply -f 04-configmap-ini.yaml
kubectl apply -f 05-secret-dba.yaml          # VSO populates Secret
kubectl wait --for=condition=ready vaultstaticsecret/virtuoso-credentials -n gmr --timeout=2m
kubectl apply -f 07-statefulset.yaml
kubectl rollout status statefulset/virtuoso -n gmr --timeout=5m

# Rotate dba away from the openlink default (the image's
# DBA_PASSWORD env init only fires reliably on a freshly-empty
# data dir; the explicit rotation is idempotent and always safe).
VAULT_PW=$(kubectl get secret -n gmr virtuoso-credentials \
    -o jsonpath='{.data.VIRTUOSO_DBA_PASSWORD}' | base64 -d)
kubectl exec -n gmr virtuoso-0 -- /opt/virtuoso-opensource/bin/isql 1111 dba dba \
    exec="user_change_password('dba', 'dba', '$VAULT_PW');"

# Internal Service first — verify Virtuoso is healthy through it.
# Apply only the `virtuoso` ClusterIP Service for now; the
# fontem-data NodePort is the cutover step further down.
awk 'BEGIN{p=1} /^---/{p=0} p' 08-services.yaml | kubectl apply -f -
kubectl exec -n gmr virtuoso-0 -- bash -c '/opt/virtuoso-opensource/bin/isql 1111 dba "$DBA_PASSWORD" exec="SPARQL ASK { ?s ?p ?o };"'
# expect: __ask_retval = 1

kubectl apply -f 09-cronjob-backup.yaml
```

### pgvector — deferred

`10-pgvector-schema.sql` is **not** applied during Phase 1.
The current `gmr/postgresql` deployment runs `postgres:16-alpine`,
which has no `vector` extension binary. Applying the schema needs
either:

- swap the image to `pgvector/pgvector:pg16` (mirror + sign first
  via the supply-chain steps above), or
- build a custom image carrying the `vector` extension.

Tracked separately. Phase 2 (sanctions ETL pilot) does not
depend on it at start.

## Cutover (§1.11 last step)

After the close-out checklist passes, swap the public NodePort
selector. Two-step swap to avoid a multi-second outage:

```
# 1. Apply the new Service in gmr ns. The default NodePort will
#    auto-pick a different port — apply, observe the assigned
#    NodePort, then patch.
kubectl apply -f 08-services.yaml

# 2. Patch the new Service to NodePort 31457 — only safe AFTER
#    the old one is deleted.
kubectl delete service fontem-data -n fontem
kubectl delete deployment fontem-data-placeholder -n fontem
kubectl patch service fontem-data -n gmr \
    --type=merge \
    -p '{"spec":{"ports":[{"name":"http","port":80,"targetPort":8890,"nodePort":31457,"protocol":"TCP"}]}}'

# 3. Verify externally
curl -I https://data.fontem.eu/sparql\?query=ASK%20%7B%7D
```

The `fontem` namespace is now empty; can be deleted once nothing
else lands there.

## Phase 1 close-out checklist

- [x] Virtuoso pod up + healthy at `https://data.fontem.eu/sparql`
  (`curl -s "https://data.fontem.eu/sparql?query=ASK%20%7B%7D"`
  returns `{"head":...,"boolean":true}`).
- [x] `dba` password rotated to the Vault-issued value (see
  the manual `user_change_password` step above).
- [x] Phase 0 ontology TBox loaded into `<…/graph/ontology>` and
  smoke fixture loaded into `<…/graph/data>` via `kubectl cp` +
  `DB.DBA.TTLP_MT(...)`. The 4 verification queries return
  expected results.
- [x] Backup CronJob has run at least once
  (`kubectl get jobs -n gmr -l role=backup`); the most recent
  `/backup/virtuoso-<stamp>/` directory contains non-empty
  `ontology.nt` + `data.nt`.
- [x] Restore drill: CLEAR + reload from .nt; the 4 verification
  queries pass against the reloaded data. (See "Restore from
  backup" below.)
- [ ] pgvector schema present in Postgres — **deferred**, see the
  pgvector section above.
- [ ] Monitoring dashboards show non-zero query latency, buffer-
  pool hit rate, disk usage — **deferred**, no Grafana scrape
  configured for Virtuoso yet.

When all green (or remaining items consciously deferred), Phase 1
closes and Phase 2 (sanctions ETL pilot) starts.

## Common ops

**Increase memory budget** (only if buffer thrashing or
OOM-kills observed):
1. Edit `04-configmap-ini.yaml` — bump `NumberOfBuffers` in
   proportion to the new cgroup.
2. Edit `07-statefulset.yaml` — bump `resources.limits.memory`.
3. Apply both. The pod restarts on the new ConfigMap hash.

**Force a rollback** (revert to the placeholder):
1. `kubectl scale statefulset virtuoso -n gmr --replicas=0`
2. Re-apply the placeholder Deployment + Service in `fontem` ns.
3. Patch the NodePort back. (Or just keep the placeholder
   manifests around in `infra/fontem-data-placeholder.yaml`.)

**Restore from backup** — full procedure (SPARQL-CONSTRUCT dumps):
1. Stop write traffic (scale down ETL CronJobs).
2. Pick the source backup: `LATEST=$(kubectl exec -n gmr virtuoso-0 -- bash -c 'ls -1d /backup/virtuoso-* | sort -r | head -1')`.
3. CLEAR target graphs (or skip if loading into a fresh pod):
   ```
   kubectl exec -n gmr -i virtuoso-0 -- /opt/virtuoso-opensource/bin/isql 1111 dba "$DBA_PASSWORD" \
       exec="SPARQL CLEAR GRAPH <http://data.fontem.eu/graph/ontology>; SPARQL CLEAR GRAPH <http://data.fontem.eu/graph/data>;"
   ```
4. Reload from the dumps via `TTLP_MT`:
   ```
   for nt in ontology data; do
       printf "DB.DBA.TTLP_MT(file_to_string_output('$LATEST/$nt.nt'), '', 'http://data.fontem.eu/graph/$nt');" \
           | kubectl exec -n gmr -i virtuoso-0 -- /opt/virtuoso-opensource/bin/isql 1111 dba "$DBA_PASSWORD"
   done
   ```
5. Re-bind the reasoner ruleset and re-materialise the property
   chain (since inferred triples aren't in the dump):
   ```
   kubectl exec -n gmr virtuoso-0 -- /opt/virtuoso-opensource/bin/isql 1111 dba "$DBA_PASSWORD" \
       exec="rdfs_rule_set('urn:fontem:phase1:rules', 'http://data.fontem.eu/graph/ontology');"
   # then re-INSERT the client/supplier chain (see tools/smoke/virtuoso/post-load.sparql)
   ```
6. Run the verification queries to confirm parity.

The scripted version lives at `tools/phase1-restore-drill.sh`
(authored during the Phase 1 restore drill).

**Why no `backup_online()`** — Virtuoso 7.2.14 has a known quirk
where `BackupDir` is read as null at the C level even when set
correctly in `[Database]` or `[Parameters]` (and even when
`cfg_item_value()` reports the right value at runtime). The
function panics with `IB007: Could not create backup file
(null)/<prefix>`. We worked around it by switching to a SPARQL-
CONSTRUCT export — small staging dataset, dumps are
version-portable, and the engine-specific binary format isn't
worth the BackupDir wrestling. Revisit if/when the dataset grows
past the point where text dumps are practical (~10M triples).
