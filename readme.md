# Installing TAP Multi-Cluster

## Create TKGS clusters

```sh
kubectx tanzu-app-platform
k apply -f multi-cluster/1-2/tap-multi-cluster-tkc.yml
```

## Prereqs - on each cluster

* Set up DNS (Has to be done _after_ everything is deployed, because we don't know the IP addresses for the LBs up front)
* Set up PodSecurityPolicy <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-prerequisites.html#kubernetes-cluster-requirements-3>

Set up PSP:

```sh
for cluster in tap-view tap-run tap-build tap-run-2
do

kubectx $cluster

kubectl create clusterrolebinding default-tkg-admin-privileged-binding --clusterrole=psp:vmware-system-privileged --group=system:authenticated

done
```

### Export version to install and dev NS

```sh
export TAP_VERSION=1.2.0
export DEVELOPER_NAMESPACE=developer-ns
```

### Install cluster essentials

* <https://docs.vmware.com/en/Cluster-Essentials-for-VMware-Tanzu/1.1/cluster-essentials/GUID-deploy.html>

Install [cluster essentials](https://network.tanzu.vmware.com/products/tanzu-cluster-essentials/):

```sh
for cluster in tap-view tap-run tap-build tap-run-2
do
kubectx $cluster

export INSTALL_BUNDLE=registry.tanzu.vmware.com/tanzu-cluster-essentials/cluster-essentials-bundle@sha256:ab0a3539da241a6ea59c75c0743e9058511d7c56312ea3906178ec0f3491f51d
export INSTALL_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
export INSTALL_REGISTRY_USERNAME=$(op item get 'Tanzu Network' --fields email --format json | jq -r .value)
export INSTALL_REGISTRY_PASSWORD=$(op item get 'Tanzu Network' --fields type=concealed --format json | jq -r .value)
./install.sh --yes
done
```

### Import TAP package repo to each cluster

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-install.html#relocate-images-to-a-registry-0>

Steps `3`, `5`, `6` and `7` from above.

```sh
for cluster in tap-view tap-run tap-build tap-run-2
do
kubectx $cluster

kubectl create ns tap-install
kubectl create ns developer-ns

tanzu secret registry add tap-registry \
  --username ${INSTALL_REGISTRY_USERNAME} --password ${INSTALL_REGISTRY_PASSWORD} \
  --server ${INSTALL_REGISTRY_HOSTNAME} \
  --export-to-all-namespaces --yes --namespace tap-install

tanzu package repository add tanzu-tap-repository \
  --url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:$TAP_VERSION \
  --namespace tap-install
done
```

## Install TAP

### Install View cluster

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-multicluster-installing-multicluster.html#install-view-cluster-2>
* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-multicluster-reference-tap-values-view-sample.html>

```sh
kubectx tap-view
tanzu package install tap -p tap.tanzu.vmware.com -v $TAP_VERSION --values-file multi-cluster/1-2/tap-values-multi-cluster-tap-view.yml -n tap-install
```

### Install Build and Run clusters and get cluster URLs and tokens for Backstage visibility

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-multicluster-installing-multicluster.html#install-build-clusters-3>
* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-multicluster-installing-multicluster.html#install-run-clusters-4>
* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-multicluster-reference-tap-values-build-sample.html>
* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-multicluster-reference-tap-values-run-sample.html>
* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-tap-gui-cluster-view-setup.html>

```sh
for cluster in tap-build tap-run tap-run-2
do
kubectx $cluster

# Install TAP
tanzu package install tap -p tap.tanzu.vmware.com -v $TAP_VERSION --values-file multi-cluster/1-2/tap-values-multi-cluster-$cluster.yml -n tap-install
# Apply multi-cluster viewer account
k apply -f multi-cluster/1-2/tap-gui-viewer-service-account-rbac.yml
# Retrieve URL and Token for viewer service account
CLUSTER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_TOKEN=$(kubectl -n tap-gui get secret $(kubectl -n tap-gui get sa tap-gui-viewer -o=json \
| jq -r '.secrets[0].name') -o=json \
| jq -r '.data["token"]' \
| base64 --decode)
# Print out each cluster's details for manual copy and paste
echo $cluster "cluster URL:" $CLUSTER_URL
echo $cluster "cluster token:" $CLUSTER_TOKEN

done
```

**Manually add the tokens above to View cluster `values.yaml`**

### Retrieve metadata store cert and auth token for build cluster

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-scst-store-ingress-multicluster.html#a-id%22multicluster-setup%22amulticluster-setup>

```sh
kubectx tap-view
CA_CERT=$(kubectl get secret -n metadata-store ingress-cert -o json | jq -r ".data.\"ca.crt\"")
AUTH_TOKEN=$(kubectl get secrets -n metadata-store -o jsonpath="{.items[?(@.metadata.annotations['kubernetes\.io/service-account\.name']=='metadata-store-read-write-client')].data.token}" | base64 -d)

cat <<EOF > multi-cluster/1-2/store_ca.yaml
---
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: store-ca-cert
  namespace: metadata-store-secrets
data:
  ca.crt: $CA_CERT
  tls.crt: ""
  tls.key: ""
EOF

# Change to Build Cluster
kubectx tap-build

# Create secrets namespace
kubectl create ns metadata-store-secrets

# Create the CA Certificate secret
kubectl apply -f multi-cluster/1-2/store_ca.yaml

# Create secret for store auth
kubectl create secret generic store-auth-token --from-literal=auth_token=$AUTH_TOKEN -n metadata-store-secrets

cat <<EOF >multi-cluster/1-2/store_secrets_export.yaml
---
apiVersion: secretgen.carvel.dev/v1alpha1
kind: SecretExport
metadata:
  name: store-ca-cert
  namespace: metadata-store-secrets
spec:
  toNamespace: scan-link-system
---
apiVersion: secretgen.carvel.dev/v1alpha1
kind: SecretExport
metadata:
  name: store-auth-token
  namespace: metadata-store-secrets
spec:
  toNamespace: scan-link-system
---
apiVersion: secretgen.carvel.dev/v1alpha1
kind: SecretExport
metadata:
  name: store-auth-token
  namespace: metadata-store-secrets
spec:
  toNamespace: developer-ns
---
apiVersion: secretgen.carvel.dev/v1alpha1
kind: SecretExport
metadata:
  name: store-ca-cert
  namespace: metadata-store-secrets
spec:
  toNamespace: developer-ns
EOF

# Export secrets to the Supply Chain Security Tools - Scan namespace
kubectl apply -f multi-cluster/1-2/store_secrets_export.yaml
```

### Add registry credentials for TAP workload push and pull to each cluster

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-set-up-namespaces.html>

```sh
for cluster in tap-run tap-run-2 tap-build
do
kubectx $cluster
export WORKLOAD_REGISTRY_HOSTNAME=harbor.ryanbaker.io
export WORKLOAD_REGISTRY_USERNAME=admin
export WORKLOAD_REGISTRY_PASSWORD=Harbor12345

tanzu secret registry add registry-credentials --server $WORKLOAD_REGISTRY_HOSTNAME --username $WORKLOAD_REGISTRY_USERNAME --password $WORKLOAD_REGISTRY_PASSWORD --namespace $DEVELOPER_NAMESPACE

cat <<EOF | kubectl -n developer-ns apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: tap-registry
  annotations:
    secretgen.carvel.dev/image-pull-secret: ""
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: e30K
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
secrets:
  - name: registry-credentials
imagePullSecrets:
  - name: registry-credentials
  - name: tap-registry
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: default-permit-deliverable
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: deliverable
subjects:
  - kind: ServiceAccount
    name: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: default-permit-workload
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: workload
subjects:
  - kind: ServiceAccount
    name: default
EOF

done
```

### Apply the Git auth secret to Build AND Run clusters

This was painful to figure out.

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-scc-gitops-vs-regops.html#pull-requests-2>
* <https://github.com/tektoncd/pipeline/blob/main/docs/auth.md#configuring-basic-auth-authentication-for-git>
* <https://github.com/tektoncd/pipeline/blob/main/docs/auth.md#configuring-ssh-auth-authentication-for-git>
* <https://github.com/tektoncd/pipeline/issues/3631#issue-762636011>

**Git PR workflow _only_ works with HTTPS auth, not SSH key**

```sh
for cluster in tap-run tap-run-2 tap-build
do
kubectx $cluster

kubectl apply -f multi-cluster/1-2/github-secret-https.yaml
done
```

### Create View metadata proxy access

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-scst-store-create-service-account-access-token.html>

```sh
kubectx tap-view

kubectl apply -f  multi-cluster/1-2/metadata-rw-client.yaml

kubectl get secret $(kubectl get sa -n metadata-store metadata-store-read-write-client -o json | jq -r '.secrets[0].name') -n metadata-store -o json | jq -r '.data.token' | base64 -d
```

**Manually add the above token to View cluster `values.yaml`** under

```yaml
tap_gui:
  app_config:
    proxy:
      /metadata-store:
        headers:
          Authorization: "Bearer <TOKEN HERE>"
```

### Configure Snyk (not part of TAP top level for some reason)

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-scst-scan-install-snyk-integration.html>

Create snyk Secret:

```yaml
cat <<EOF > multi-cluter/1-2/snyk-secret.yaml
---
apiVersion: v1
data:
  snyk_token: SNYK_API_TOKEN_HERE
kind: Secret
metadata:
  name: snyk-api-token
  namespace: developer-ns
type: Opaque
EOF
```

Apply to cluster:

```sh
k apply -f multi-cluster/1-2/snyk-secret.yaml 
```

Create a discrete `values.yaml` for Snyk:

```yaml
cat <<EOF > multi-cluter/1-2/snyk-values.yaml
---
namespace: developer-ns
targetImagePullSecret: tap-registry
snyk:
  tokenSecret:
    name: snyk-api-token
metadataStore:
  url: https://metadata-store.tap-mc.labs.satm.eng.vmware.com
  caSecret:
    name: store-ca-cert
    importFromNamespace: "" #! since both snyk and grype both enable store, one must leave importFromNamespace blank
  authSecret:
    name: store-auth-token
    importFromNamespace: "" #! since both snyk and grype both enable store, one must leave importFromNamespace blank
EOF
```

Install Snyk:

```sh
tanzu package install snyk-scanner \
  --package-name snyk.scanning.apps.tanzu.vmware.com \
  --version 1.0.0-beta.2 \
  --namespace tap-install \
  --values-file multi-cluster/1-2/snyk-values.yml
```

Update Build cluster `values.yaml` to target OOTB supply chain to use Snyk for image scanning:

```yaml
ootb_supply_chain_testing_scanning:
  scanning:
    image:
      template: snyk-private-image-scan-template
      policy: scan-policy
```

```sh
kubectx tap-build
tanzu package installed update tap -p tap.tanzu.vmware.com -v $TAP_VERSION  --values-file multi-cluster/1-2/tap-values-multi-cluster-tap-build.yml -n tap-install
```

### Configure `ScanTemplate` and `ScanPolicy`

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-scc-ootb-supply-chain-testing-scanning.html#scan-policy>
* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-scc-ootb-supply-chain-testing-scanning.html#scan-template>

```sh
k apply -f multi-cluster/1-2/scan-policy.yaml
```

### Configure Tekton `Pipeline`

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-scc-ootb-supply-chain-testing.html#updates-to-the-developer-namespace-2>

```sh
k apply -f multi-cluster/1-2/tekton-pipeline.yaml
```

## Test out TAP

* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-multicluster-getting-started.html#start-the-workload-on-the-build-profile-cluster-1>
* <https://docs-staging.vmware.com/en/draft/VMware-Tanzu-Application-Platform/1.2/tap/GUID-scc-ootb-supply-chain-testing.html#developer-workload-3>

```sh
# Change to build cluster
kubectx tap-build 

# Create app
tanzu apps workload create tanzu-java-web-app \
--git-repo https://github.com/mylesagray/tanzu-java-web-app/ \
--git-branch main \
--type web \
--label app.kubernetes.io/part-of=tanzu-java-web-app \
--yes \
--namespace $DEVELOPER_NAMESPACE

# Tail app
tanzu apps workload tail tanzu-java-web-app --since 10m --timestamp --namespace $DEVELOPER_NAMESPACE

# Get deliverable off the build cluster, modify with jq to remove metadata and change target gitops branches
kubectl get deliverable tanzu-java-web-app --namespace $DEVELOPER_NAMESPACE -o json > multi-cluster/1-2/deliverable-temp.json
jq 'del(.status)' multi-cluster/1-2/deliverable-temp.json | jq 'del(.metadata.ownerReferences)' > multi-cluster/1-2/deliverable.json && rm -rf multi-cluster/1-2/deliverable-temp.json
jq '.spec.source.git.ref.branch |= "staging"' multi-cluster/1-2/deliverable.json > multi-cluster/1-2/deliverable-staging.json
jq '.spec.source.git.ref.branch |= "main"' multi-cluster/1-2/deliverable.json > multi-cluster/1-2/deliverable-live.json
rm -rf multi-cluster/1-2/deliverable.json

# Apply deliverable to both run clusters
kubectx tap-run

kubectl apply -f multi-cluster/1-2/deliverable-staging.json --namespace $DEVELOPER_NAMESPACE
kubectl get deliverables --namespace $DEVELOPER_NAMESPACE
kubectl get httpproxy --namespace $DEVELOPER_NAMESPACE

kubectx tap-run-2

kubectl apply -f multi-cluster/1-2/deliverable-live.json --namespace $DEVELOPER_NAMESPACE
kubectl get deliverables --namespace $DEVELOPER_NAMESPACE
kubectl get httpproxy --namespace $DEVELOPER_NAMESPACE

# Open the app URLs to test
open http://tanzu-java-web-app.developer-ns.staging.tap-mc.labs.satm.eng.vmware.com
open http://tanzu-java-web-app.developer-ns.live.tap-mc.labs.satm.eng.vmware.com
```

## Update TAP

```sh
export DEVELOPER_NAMESPACE=developer-ns
export TAP_VERSION=1.2.0
export SNYK_VERSION=1.0.0-beta.2
./multi-cluster/update.sh
```
