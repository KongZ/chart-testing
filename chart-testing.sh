#!/usr/bin/env bash

set -o errexit
set -o pipefail

CHART_TESTING_IMAGE="quay.io/helmpack/chart-testing"
CHART_TESTING_TAG="v2.1.0"
K8S_VERSION="v1.11.3"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
## Jenkins on th0host0 can't delete file
KEEP_FILE_AFTER_BUILD=true
TARGET_BRANCH="${TARGET_BRANCH:-develop}"

run_kind() {
  echo "Getting kind ..."
  install_kind

  echo "Create Kubernetes cluster with kind..."
  KIND_IS_UP=true
  kind create cluster --image=kindest/node:"$K8S_VERSION"

  echo "Export kubeconfig..."
  # shellcheck disable=SC2155
  export KUBECONFIG="$(kind get kubeconfig-path)"

  echo "Ensure the apiserver is responding..."
  kubectl cluster-info

  echo "Wait for Kubernetes to be up and ready..."
  JSONPATH='{range .items[*]}{@.metadata.name}:{range @.status.conditions[*]}{@.type}={@.status};{end}{end}'; until kubectl get nodes -o jsonpath="$JSONPATH" 2>&1 | grep -q "Ready=True"; do sleep 1; done
}

# install kind to a tempdir GOPATH from this script's kind checkout
install_kind() {
  # install `kind` to tempdir
  TMP_DIR=$(mktemp -d)
  # ensure bin dir
  mkdir -p "${TMP_DIR}/bin"
  # if we have a kind checkout, install that to the tmpdir, otherwise go get it
  echo "Install kind to ${TMP_DIR}..."
  docker run --rm -v "${TMP_DIR}":/go -e "GOPATH=/go" golang:stretch go get sigs.k8s.io/kind
  PATH="${TMP_DIR}/bin:${PATH}"
  export PATH
}

install_tiller() {
  # Install Tiller with RBAC
  kubectl -n kube-system create sa tiller 
  kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
  docker exec "$container_id" helm init --service-account tiller
  echo "Wait for Tiller to be up and ready..."
  until kubectl -n kube-system get pods 2>&1 | grep -w "tiller-deploy"  | grep -w "1/1"; do sleep 1; done
}

install_hostpath_provisioner() {
   # kind doesn't support Dynamic PVC provisioning yet, this one of ways to get it working
   # https://github.com/rimusz/charts/tree/master/stable/hostpath-provisioner

   # delete the default storage class
   kubectl delete storageclass standard

   echo "Install Hostpath Provisioner..."
   docker exec "$container_id" helm repo add rimusz https://charts.rimusz.net
   docker exec "$container_id" helm repo update
   docker exec "$container_id" helm upgrade --install hostpath-provisioner --namespace kube-system rimusz/hostpath-provisioner
}

# our exit handler (trap)
cleanup() {
  echo "Events Summary"
  kubectl -n "$namespace" get events --sort-by='{.lastTimestamp}'

  # KIND_IS_UP is true once we: kind create
  if [[ "${KIND_IS_UP:-}" = true ]]; then
    kind delete cluster || true
  fi
  docker rm -f $container_id > /dev/null
  # remove our tempdir
  # NOTE: this needs to be last, or it will prevent kind delete
  if [[ "${KEEP_FILE_AFTER_BUILD:-}" = false ]]; then  
    if [[ -n "${TMP_DIR:-}" ]]; then
      rm -rf "${TMP_DIR}"
    fi
  fi
}


main() {
  ## ct auto-detect changing charts does not work with Jenkins `checkout scm`
  echo "Finding changing charts... ${TARGET_BRANCH}"
  charts=$(git diff --name-only ${TARGET_BRANCH} | grep '/' | awk -F/ '{print $1}' | uniq | fgrep -vf chart-testing.ignore | tr '\n' ',' | sed '$s/,$//')
  if [[ -z "$charts" ]]; then
    echo "No charts change"
    exit 0
  fi

  trap cleanup EXIT

  ## Start chart-testing container
  container_id=$(docker run -it -d -v "$REPO_ROOT:/workdir" --workdir /workdir "$CHART_TESTING_IMAGE:$CHART_TESTING_TAG" cat)

  echo "Checking charts... $charts"
  docker exec "$container_id" ct lint --config /workdir/ct.yaml --chart-dirs /workdir --chart-yaml-schema /workdir/chart-schema.yaml --check-version-increment --charts "$charts"

  echo "Starting kind ..."
  run_kind

  echo "Preparing cluster..." 
  # Get kind container IP
  kind_container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kind-1-control-plane)
  # Copy kubeconfig file
  docker exec "$container_id" mkdir /root/.kube
  docker cp "$KUBECONFIG" "$container_id:/root/.kube/config"
  # Update in kubeconfig from localhost to kind container IP
  docker exec "$container_id" sed -i "s/localhost:.*/$kind_container_ip:6443/g" /root/.kube/config

  # Download private kubeconfig
  # A Hacking way to reuse configuration from another cluster
  if [[ ! -z "$PRIVATE_KUBECONFIG" ]]; then
    echo "Downloading private kubeconfig"
    docker cp "$PRIVATE_KUBECONFIG" "$container_id:/root/.kube/private_config"
  fi

  # Install Tiller with RBAC
  install_tiller

  # Install hostpath-provisioner for Dynamic PVC provisioning
  install_hostpath_provisioner

  # Register private registry
  namespace=$(openssl rand -hex 8)
  if [[ ! -z "$GCLOUD_KEY" ]]; then
    echo "Setting gcloud key on $namespace"
    # namespace = $(helm list | grep "$charts" | awk '{print $NF}')
    kubectl -n $namespace create namespace "$namespace"
    kubectl -n $namespace create secret docker-registry regcred --docker-server="https://asia.gcr.io" --docker-username="_json_key" --docker-password="$(cat $GCLOUD_KEY)" --docker-email="devops@omise.co"
    echo "Patching service account on $namespace"
    kubectl -n $namespace patch serviceaccount default -p "{\"imagePullSecrets\": [{\"name\": \"regcred\"}]}"
  fi

  echo "Installing chart... $charts" 
  # docker exec -e "KUBECONFIG=/root/.kube/config:/root/.kube/private_config" "$container_id" ct install --config /workdir/ct.yaml --charts "$charts" --namespace="$namespace" --helm-extra-args "--timeout 500 --tiller-namespace kube-system --tiller-connection-timeout 30" --debug
  docker exec "$container_id" ct install --config /workdir/ct.yaml --charts "$charts" --namespace="$namespace" --helm-extra-args "--timeout 500 --tiller-namespace kube-system --tiller-connection-timeout 30"
  echo "Done Testing!"
}

main