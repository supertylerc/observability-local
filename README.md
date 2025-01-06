# local observability with Talos

Uses `talos cluster create` to create a cluster in Docker, podman, etc.

## Important ENV Vars

The following environment variables have the following effects:

* `OBS_LAB_DELETE_KUBECONFIG`: When set, executes `rm ~/.kube/config`
    * When not set, you may need to perform extra steps to have a functioning cluster/user/context
* `OBS_LAB_DESTROY_CLUSTER`: When set, executes `talos cluster destroy`
    * When not sent, things may be unpredictable and/or not work.  **Use at your own risk.**

## `provision.sh` Overview

1. Destroy any existing clusters, if `OBS_LAB_DESTROY_CLUSTER` env var is set
2. Delete `~/.kube/config`, if `OBS_LAB_DELETE_KUBECONFIG` env var is set
3. Create a Talos Cluster with `talos cluster create`:
    1. 1 worker with 3 CPU and 4G RAM using `control-plane-patch.yaml`
    2. 1 worker with 3 CPU and 12G RAM
    3. All nodes get `all-nodes-patch.yaml`
    4. Installs Cilium without kube-proxy and ArgoCD using inline manifests
4. Wait for ArgoCD install to complete
5. Delete privileged SA and ClusterRoleBinding that were used for installing Cilium and ArgoCD
6. Install main ArgoCD apps
7. Wait for main ArgoCD apps to finish installing
8. Apply k8s manifests which require CRDs from installed Argo Apps

## Result

You should have a Kubernetes cluster running Talos.  It should have the following:

* Cluster
    * Talos
    * Cilium deployed in `strict` mode (no `kube-proxy`)
    * Kubernetes Audit Logs
        * Creates a `Config` to ship to Falco's k8saudit webhook
        * Uses `.cluster.apiServer.extraVolumes[]` to mount the `Config` into the Kube API Server static pod
        * Uses `.cluster.apiServer.extraArgs` to add the `--audit-webhook-config-file` arg to the Kube API Server static pod
    * Ignore PodSecurity for the following namespaces to ease observability needs:
        * falco (eBPF)
        * beyla (eBPF)
        * cilium (eBPF)
        * monitoring
        * otel (mounts host volumes)
    * Creates an SA and admin ClusterRoleBinding
        * Used for creating and running `helm upgrade --install` in a Kubernetes `Job` to faciliate the installation of both Cilium and ArgoCD
        * Deleted by `provision.sh` after ArgoCD is installed successfully
    * ArgoCD for GitOps
    * Creates SA, ClusterRole, and ClusterRoleBinding for OTEL to be able to read and extract metadata for logs
* Telemetry
    * Falco
        * `modern_ebpf` mode for watching `syscall`s
        * Sets up the `k8saudit` plugin to receive Kubernetes API Audit Logs and create events based on Kubernetes API Audit Logs
        * Uses mature rulesets for `syscall` and `k8saudit` plugin
        * Sidekick
            * UI with default credentials of `admin/admin`
            * Forwards events to Loki
    * OpenTelemetry Operator
        * Allows for creating OpenTelemetry Collectors
    * OpenTelemetry Collectors
        * Pod Logs
            * Mounts host's `/var/log/pods/**/*.log`
            * Extracts metadata about the pods to add to the log
            * Forwards to Loki with the added metadata
        * Kubernetes Audit Logs
            * Mounts host's `/var/log/audit/kube/*.log`
            * Forwards to Loki as-is
    * Logs (Loki)
        * Receives logs from OTEL Log Collectors and Falco Sidekick
        * Single Binary Mode
        * Uses bundled MinIO for persistent storage
    * Metrics
        * kube-prometheus-stack
            * Deploys Prometheus Operator, KSM, Node Exporter, and a Prometheus instance
            * Configures Thanos sidecar object store config
        * Thanos
            * Aggregates multiple Prometheus instances
            * Persistence via bundled MinIO
    * Traces
        * Tempo
            * Single Binary Mode
            * No persistent storage
    * Grafana
        * Backends for Tempo, Thanos, and Loki already configured
* Telepresence for accessing services directly instead of 9000 `kubectl port-forward` terminals
    * `telepresence connect`, then use k8s DNS names natively (excluding Ingress/Gateway!)
* ingress-nginx for deploying Ingress objects
    * NB: Ingress mostly doesn't work without extra hoops, particularly on macOS, but this is still here so that the configuration can be validated
* cert-manager for OTEL's dependencies
    * NB: Currently not tuned or tested for more general certificate usage
* harbor for pushing images

## Poking About

* Install telepresence.  On macOS:

```
brew install telepresenceio/telepresence/telepresence-oss

```

* Connect to your cluster:

```
telepresence connect
```

> You will be asked for your sudo passowrd.

* Find a service with `kubectl get svc -A`, then open your browser to `http://$SERVICE.$NAMESPACE.svc:$PORT`.  For example, for Falco Sidekick UI:

```
❯ k get svc -n falco falco-falcosidekick-ui
NAME                     TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
falco-falcosidekick-ui   ClusterIP   10.98.148.77   <none>        2802/TCP   81m

❯ open http://falco-falcosidekick-ui.falco.svc:2802
```

* Continue exploring/leveraging the tools that are deployed.  Deploy your own.  Go wild.

## Logins

* ArgoCD

Username: `admin`.  Passowrd:

```
k get secret -n argocd argocd-initial-admin-secret -o yaml | yq -e '.data.password' | base64 -d | pbcopy
```

* Harbor

Username: `admin`.  Password:

```
k get secret -n harbor harbor-core-envvars -o yaml | yq -e '.data.HARBOR_ADMIN_PASSWORD' | base64 -d | pbcopy
```

## Publishing Images

* Login with credentials above:

```
podman login harbor.harbor.svc
```

* Build image:

```
podman build --tag harbor.harbor.svc/library/test-img .
```

* Push image:

```
podman push harbor.harbor.svc/library/test-img:latest --tls-verify=false
```

* Verify you can run a pod from Harbor:

```
❯ k run -it --rm debug --image=harbor.harbor.svc/library/test-img --restart=Never -- sh
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "debug" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "debug" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "debug" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "debug" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
If you don't see a command prompt, try pressing enter.

# ls
bin  boot  dev  etc  home  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
#
pod "debug" deleted
```
