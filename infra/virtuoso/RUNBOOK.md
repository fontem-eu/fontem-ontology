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

```
kubectl apply -f 01-pv-data.yaml
kubectl apply -f 02-pv-backup.yaml
kubectl apply -f 03-pvcs.yaml
kubectl apply -f 04-configmap-ini.yaml
kubectl apply -f 05-secret-dba.yaml          # VSO populates Secret
kubectl wait --for=condition=ready vaultstaticsecret/virtuoso-credentials -n gmr --timeout=2m
kubectl apply -f 07-statefulset.yaml
kubectl rollout status statefulset/virtuoso -n gmr --timeout=5m

# pgvector sidecar in the existing Postgres
kubectl cp 10-pgvector-schema.sql gmr/$(kubectl get pod -n gmr -l app=postgres -o jsonpath='{.items[0].metadata.name}'):/tmp/
kubectl exec -n gmr deploy/postgres -- psql -U postgres -f /tmp/10-pgvector-schema.sql

# Internal Service first — verify Virtuoso is healthy through it
kubectl apply -f 08-services.yaml      # only the `virtuoso` Service section
kubectl run smoke-probe -n gmr --rm -it --image=curlimages/curl --restart=Never -- \
    curl -sS "http://virtuoso.gmr.svc.cluster.local:8890/sparql?query=ASK%20%7B%7D"
# expect: {"head":{"link":[]},"boolean":true}

kubectl apply -f 09-cronjob-backup.yaml
```

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

- [ ] Virtuoso pod up + healthy at `https://data.fontem.eu/sparql`
  (after the NodePort cutover above).
- [ ] `dba` password rotated to a Vault-issued value (verify by
  checking that `vault kv get secret/gmr/virtuoso` returns a long
  random password and that `kubectl exec ... isql -P "$DBA_PASSWORD"`
  succeeds).
- [ ] Phase 0 ontology TBox loaded into `<…/graph/ontology>`:
  ```
  for f in ontology/{core,procurement,corporate,lobbying,sanctions,cohesion,geo,meta}.ttl; do
      curl -u admin:$DBA_PASSWORD \
          -X POST "http://virtuoso.gmr.svc.cluster.local:8890/sparql-graph-crud-auth?graph=http://data.fontem.eu/graph/ontology" \
          -H 'Content-Type: text/turtle' --data-binary "@$f"
  done
  ```
- [ ] Phase 0 smoke fixture loaded into `<…/graph/data>`. The 4
  verification queries return expected results against this
  Virtuoso (not the Docker smoke).
- [ ] Backup CronJob has run at least once
  (`kubectl get jobs -n gmr -l role=backup`); the most recent
  output directory in `/backup` is non-empty.
- [ ] Restore drill: spin a throwaway pod from the backup, run
  one verification query, confirm the result matches.
- [ ] pgvector schema present in Postgres (`\dt vectors.*`).
- [ ] Monitoring dashboards show non-zero query latency,
  buffer-pool hit rate, disk usage.

When all green, Phase 1 closes and Phase 2 (sanctions ETL pilot)
starts.

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

**Restore from backup** — full procedure:
1. Stop write traffic (scale down ETL CronJobs).
2. `kubectl scale statefulset virtuoso -n gmr --replicas=0`
3. Pick a backup directory under `/backup`.
4. Mount the backup PVC into a maintenance pod, copy the dump
   files into a fresh `/database`.
5. Scale Virtuoso back to 1 with `replicas=1`.
6. Wait for readiness.
7. Run the verification queries.

A scripted version lives at `tools/restore.sh` (TODO during
restore drill).
