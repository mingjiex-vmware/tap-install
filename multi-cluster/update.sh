#!/bin/bash
export KUBECTL_VSPHERE_PASSWORD=$(op item get 'TMM Shared Lab Myles' --fields type=concealed --format json | jq -r .value)
kubectl vsphere login --insecure-skip-tls-verify --server=https://10.198.53.128 -u ad-mylesg@satm.eng.vmware.com --tanzu-kubernetes-cluster-name tap-view
kubectl vsphere login --insecure-skip-tls-verify --server=https://10.198.53.128 -u ad-mylesg@satm.eng.vmware.com --tanzu-kubernetes-cluster-name tap-build
kubectl vsphere login --insecure-skip-tls-verify --server=https://10.198.53.128 -u ad-mylesg@satm.eng.vmware.com --tanzu-kubernetes-cluster-name tap-run
kubectl vsphere login --insecure-skip-tls-verify --server=https://10.198.53.128 -u ad-mylesg@satm.eng.vmware.com --tanzu-kubernetes-cluster-name tap-run-2

export DEVELOPER_NAMESPACE=developer-ns

for cluster in tap-view tap-run tap-run-2 tap-build
do
kubectx $cluster

tanzu package repository update tanzu-tap-repository \
--url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:$TAP_VERSION \
--namespace tap-install

tanzu package repository get tanzu-tap-repository --namespace tap-install
done

for cluster in tap-view tap-run tap-run-2 tap-build
do
kubectx $cluster

tanzu package installed update tap -p tap.tanzu.vmware.com -v $TAP_VERSION  --values-file multi-cluster/1-2/tap-values-multi-cluster-$cluster.yml -n tap-install
done

kubectx tap-build

tanzu package installed update snyk-scanner -p snyk.scanning.apps.tanzu.vmware.com -v $SNYK_VERSION --values-file multi-cluster/1-2/snyk-values.yml -n tap-install