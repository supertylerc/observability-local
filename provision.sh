#!/bin/bash
[[ -n ${OBS_LAB_DESTROY_CLUSTER} ]] && echo "Destroying current cluster" && talosctl cluster destroy

[[ -n ${OBS_LAB_DELETE_KUBECONFIG} ]] && echo "Deleting ~/.kube/config" && rm ~/.kube/config

echo "Creating new Talos Cluster"
talosctl cluster create \
    --workers 1 \
    --memory 4096 \
    --memory-workers 12288 \
    --cpus 3.0 \
    --cpus-workers 3.0 \
    --config-patch @all-nodes-patch.yaml \
    --config-patch-control-plane @control-plane-patch.yaml \
    --registry-insecure-skip-verify harbor.harbor.svc

echo "Waiting for ArgoCD"
until kubectl get job -n kube-system argocd-install -o json | jq -e '.status.succeeded==1' > /dev/null; do
    sleep 5
    echo "Still waiting for ArgoCD..."
done

echo "Deleting SA and CRB with elevated privileges"
kubectl delete sa helm-install -n kube-system
kubectl delete clusterrolebinding helm-install

echo "Creating ArogCD Main Apps"
for fname in argo/*yaml; do
    kubectl apply -f $fname
done

echo "Waiting for ArgoCD Main Apps to Finish"
until [[ $(kubectl get app -n argocd | grep -cv "Synced.*Healthy\|NAME") = 0 ]]; do
    sleep 5
    echo "Still waiting for ArgoCD Main Apps to Finish..."
done

echo "Install ArgoCD Apps That Needed CRDs from Main Apps"
for fname in argo/crs/*yaml; do
    kubectl apply -f $fname
done
