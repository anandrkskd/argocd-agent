#!/bin/bash
# Copyright 2025 The argocd-agent Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

##############################################################################
# Script to set up a kind-based development environment for argocd-agent.
#
# WARNING: Development script. Do not use for production.
#
# Creates three kind clusters:
#   - argocd-hub          (control plane with principal)
#   - argocd-agent-managed    (workload cluster, managed mode)
#   - argocd-agent-autonomous (workload cluster, autonomous mode)
#
# Uses podman as the container runtime for building images and as
# the kind provider.
#
# Usage:
#   ./setup-kind-env.sh create   # Set up everything
#   ./setup-kind-env.sh delete   # Tear down everything
#   ./setup-kind-env.sh status   # Show cluster and pod status
##############################################################################

set -e
set -o pipefail

# enable for debugging:
# set -x

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
BASEPATH="$( cd -- "$(dirname "$0")/../.." >/dev/null 2>&1 ; pwd -P )"

source ${SCRIPTPATH}/namespaces.sh

AGENTCTL=${BASEPATH}/dist/argocd-agentctl

# Cluster names (kind prefixes "kind-" to context names)
HUB_CLUSTER_NAME="argocd-hub"
MANAGED_CLUSTER_NAME="argocd-agent-managed"
AUTONOMOUS_CLUSTER_NAME="argocd-agent-autonomous"

HUB_CONTEXT="kind-${HUB_CLUSTER_NAME}"
MANAGED_CONTEXT="kind-${MANAGED_CLUSTER_NAME}"
AUTONOMOUS_CONTEXT="kind-${AUTONOMOUS_CLUSTER_NAME}"

# CIDR ranges (non-overlapping per cluster)
HUB_POD_CIDR="10.245.0.0/16"
HUB_SVC_CIDR="10.97.0.0/12"
MANAGED_POD_CIDR="10.246.0.0/16"
MANAGED_SVC_CIDR="10.98.0.0/12"
AUTONOMOUS_POD_CIDR="10.247.0.0/16"
AUTONOMOUS_SVC_CIDR="10.99.0.0/12"

# Image settings
IMAGE_TAG="local-dev"
LOCAL_IMAGE="localhost/argocd-agent:${IMAGE_TAG}"

# Use podman as kind provider
export KIND_EXPERIMENTAL_PROVIDER=podman

action="$1"
shift || true

required_binaries="kubectl kind podman kustomize jq"
for bin in $required_binaries; do
    which $bin >/dev/null 2>&1 || (echo "Required binary $bin not found in \$PATH" >&2; exit 1)
done

if ! test -x ${AGENTCTL}; then
    echo "argocd-agentctl not found at ${AGENTCTL}." >&2
    echo "Please build it first by running 'make cli'" >&2
    exit 1
fi

initial_context=$(kubectl config current-context 2>/dev/null || echo "")
WORK_TMPDIR=""

cleanup() {
    if [ -n "${initial_context}" ]; then
        kubectl config use-context ${initial_context} 2>/dev/null || true
    fi
    if [ -n "${WORK_TMPDIR}" ] && [ "${WORK_TMPDIR}" != "/" ] && [ -d "${WORK_TMPDIR}" ]; then
        echo "=> Removing temp path ${WORK_TMPDIR}"
        rm -rf ${WORK_TMPDIR}
    fi
}

on_error() {
    echo "ERROR: Error occurred, terminating." >&2
    cleanup
}

trap cleanup EXIT
trap on_error ERR

wait_for_pods_kind() {
    context="$1"
    component="$2"
    ns="$3"

    echo "  -> Waiting for ${component} pods in ${ns} on ${context}"
    case "$component" in
    "principal")
        kubectl --context $context -n $ns rollout status --watch --timeout=180s deployments argocd-server
        kubectl --context $context -n $ns rollout status --watch --timeout=180s deployments argocd-repo-server
        kubectl --context $context -n $ns rollout status --watch --timeout=180s deployments argocd-dex-server
        kubectl --context $context -n $ns rollout status --watch --timeout=180s deployments argocd-redis
        ;;
    "agent")
        kubectl --context $context -n $ns rollout status --watch --timeout=180s statefulsets argocd-application-controller
        kubectl --context $context -n $ns rollout status --watch --timeout=180s deployments argocd-repo-server
        kubectl --context $context -n $ns rollout status --watch --timeout=180s deployments argocd-redis
        ;;
    *)
        echo "Unknown component: $component"
        exit 1
        ;;
    esac
}

create_kind_cluster() {
    name="$1"
    pod_cidr="$2"
    svc_cidr="$3"

    if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
        echo "  -> Cluster ${name} already exists, skipping"
        return 0
    fi

    cat <<EOF | kind create cluster --name ${name} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${name}
networking:
  podSubnet: "${pod_cidr}"
  serviceSubnet: "${svc_cidr}"
nodes:
  - role: control-plane
EOF
    kubectl --context kind-${name} wait --for=condition=Ready nodes --all --timeout=120s
}

get_hub_container_ip() {
    podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${HUB_CLUSTER_NAME}-control-plane
}

do_create() {
    echo "=== Building local argocd-agent image ==="
    (cd ${BASEPATH} && podman build -t ${LOCAL_IMAGE} .)

    echo "=== Creating kind clusters ==="
    echo "-> Creating hub cluster (${HUB_CLUSTER_NAME})"
    create_kind_cluster ${HUB_CLUSTER_NAME} ${HUB_POD_CIDR} ${HUB_SVC_CIDR}

    echo "-> Creating managed agent cluster (${MANAGED_CLUSTER_NAME})"
    create_kind_cluster ${MANAGED_CLUSTER_NAME} ${MANAGED_POD_CIDR} ${MANAGED_SVC_CIDR}

    echo "-> Creating autonomous agent cluster (${AUTONOMOUS_CLUSTER_NAME})"
    create_kind_cluster ${AUTONOMOUS_CLUSTER_NAME} ${AUTONOMOUS_POD_CIDR} ${AUTONOMOUS_SVC_CIDR}

    echo "=== Loading image into clusters ==="
    for cluster in ${HUB_CLUSTER_NAME} ${MANAGED_CLUSTER_NAME} ${AUTONOMOUS_CLUSTER_NAME}; do
        echo "  -> Loading ${LOCAL_IMAGE} into ${cluster}"
        kind load docker-image ${LOCAL_IMAGE} --name ${cluster}
    done

    echo "=== Creating namespaces ==="
    kubectl create namespace ${ARGOCD_PRINCIPAL_NAMESPACE} --context ${HUB_CONTEXT} 2>/dev/null || true
    kubectl create namespace ${ARGOCD_MANAGED_NAMESPACE} --context ${MANAGED_CONTEXT} 2>/dev/null || true
    kubectl create namespace ${ARGOCD_AUTONOMOUS_NAMESPACE} --context ${AUTONOMOUS_CONTEXT} 2>/dev/null || true

    echo "=== Installing Argo CD ==="
    WORK_TMPDIR=$(mktemp -d /tmp/argocd-agent-kind.XXXXXXXX)
    cp -a ${BASEPATH}/install/kubernetes/* ${WORK_TMPDIR}

    install_argocd_with_namespace() {
        local kustomize_dir="$1"
        local target_ns="$2"
        local target_ctx="$3"

        (
            cd ${kustomize_dir}
            kustomize edit set namespace ${target_ns}
            cat >> kustomization.yaml <<NSEOF

transformers:
- |-
  apiVersion: builtin
  kind: NamespaceTransformer
  metadata:
    name: argocd-namespace-transformer
    namespace: ${target_ns}
  setRoleBindingSubjects: allServiceAccounts
NSEOF
        )
        kustomize build ${kustomize_dir} | kubectl apply --server-side --context ${target_ctx} -f - || true
        kustomize build ${kustomize_dir} | kubectl apply --server-side --context ${target_ctx} -f -
    }

    echo "-> Installing Argo CD on hub (principal config)"
    install_argocd_with_namespace ${WORK_TMPDIR}/argo-cd/principal ${ARGOCD_PRINCIPAL_NAMESPACE} ${HUB_CONTEXT}

    echo "-> Installing Argo CD on managed agent"
    install_argocd_with_namespace ${WORK_TMPDIR}/argo-cd/agent-managed ${ARGOCD_MANAGED_NAMESPACE} ${MANAGED_CONTEXT}

    echo "-> Installing Argo CD on autonomous agent"
    install_argocd_with_namespace ${WORK_TMPDIR}/argo-cd/agent-autonomous ${ARGOCD_AUTONOMOUS_NAMESPACE} ${AUTONOMOUS_CONTEXT}

    echo "-> Patching apps-in-any-namespace on hub"
    kubectl patch configmap argocd-cmd-params-cm \
        -n ${ARGOCD_PRINCIPAL_NAMESPACE} \
        --context ${HUB_CONTEXT} \
        --patch '{"data":{"application.namespaces":"*"}}' || true

    kubectl rollout restart deployment argocd-server \
        -n ${ARGOCD_PRINCIPAL_NAMESPACE} --context ${HUB_CONTEXT}

    echo "-> Generating server.secretkey for agent ArgoCD secrets"
    if ! pwmake=$(which pwmake 2>/dev/null); then
        pwmake=$(which pwgen 2>/dev/null) || pwmake=""
    fi
    base64cmd=$(which base64)
    if [[ "$OSTYPE" != "darwin"* ]]; then
        base64cmd="$(which base64) -w0"
    fi

    if [ -n "$pwmake" ]; then
        managed_secret_key=$($pwmake 56 | $base64cmd)
        autonomous_secret_key=$($pwmake 56 | $base64cmd)
    else
        managed_secret_key=$(openssl rand -base64 32 | $base64cmd)
        autonomous_secret_key=$(openssl rand -base64 32 | $base64cmd)
    fi

    kubectl patch secret argocd-secret -n ${ARGOCD_MANAGED_NAMESPACE} \
        --context ${MANAGED_CONTEXT} \
        --patch="{\"data\":{\"server.secretkey\":\"${managed_secret_key}\"}}" 2>/dev/null || true
    kubectl patch secret argocd-secret -n ${ARGOCD_AUTONOMOUS_NAMESPACE} \
        --context ${AUTONOMOUS_CONTEXT} \
        --patch="{\"data\":{\"server.secretkey\":\"${autonomous_secret_key}\"}}" 2>/dev/null || true

    echo "=== Waiting for Argo CD pods ==="
    wait_for_pods_kind ${HUB_CONTEXT} principal ${ARGOCD_PRINCIPAL_NAMESPACE}
    wait_for_pods_kind ${MANAGED_CONTEXT} agent ${ARGOCD_MANAGED_NAMESPACE}
    wait_for_pods_kind ${AUTONOMOUS_CONTEXT} agent ${ARGOCD_AUTONOMOUS_NAMESPACE}

    echo "=== Setting up PKI ==="
    echo "-> Initializing PKI"
    if ! ${AGENTCTL} pki inspect --principal-context ${HUB_CONTEXT} --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE} >/dev/null 2>&1; then
        ${AGENTCTL} pki init \
            --principal-context ${HUB_CONTEXT} \
            --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE}
        echo "  -> PKI initialized."
    else
        echo "  -> Reusing existing agent PKI."
    fi

    HUB_IP=$(get_hub_container_ip)
    echo "  -> Hub container IP: ${HUB_IP}"

    echo "-> Issuing principal TLS certificate"
    PRINCIPAL_DNS_NAME=$(kubectl get svc argocd-agent-principal \
        -n ${ARGOCD_PRINCIPAL_NAMESPACE} --context ${HUB_CONTEXT} \
        -o jsonpath='{.metadata.name}.{.metadata.namespace}.svc.cluster.local' 2>/dev/null || echo "argocd-agent-principal.${ARGOCD_PRINCIPAL_NAMESPACE}.svc.cluster.local")

    ${AGENTCTL} pki issue principal \
        --principal-context ${HUB_CONTEXT} \
        --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE} \
        --ip 127.0.0.1,${HUB_IP} \
        --dns localhost,${PRINCIPAL_DNS_NAME} \
        --upsert

    echo "-> Issuing resource proxy TLS certificate"
    RESOURCE_PROXY_IP=$(kubectl get svc argocd-agent-resource-proxy \
        -n ${ARGOCD_PRINCIPAL_NAMESPACE} --context ${HUB_CONTEXT} \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    RESOURCE_PROXY_DNS=$(kubectl get svc argocd-agent-resource-proxy \
        -n ${ARGOCD_PRINCIPAL_NAMESPACE} --context ${HUB_CONTEXT} \
        -o jsonpath='{.metadata.name}.{.metadata.namespace}.svc.cluster.local' 2>/dev/null || echo "argocd-agent-resource-proxy.${ARGOCD_PRINCIPAL_NAMESPACE}.svc.cluster.local")

    PROXY_IP_ARGS="--ip 127.0.0.1"
    if [ -n "${RESOURCE_PROXY_IP}" ]; then
        PROXY_IP_ARGS="--ip 127.0.0.1,${RESOURCE_PROXY_IP}"
    fi

    ${AGENTCTL} pki issue resource-proxy \
        --principal-context ${HUB_CONTEXT} \
        --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE} \
        ${PROXY_IP_ARGS} \
        --dns localhost,${RESOURCE_PROXY_DNS} \
        --upsert

    echo "-> Creating JWT signing key"
    ${AGENTCTL} jwt create-key \
        --principal-context ${HUB_CONTEXT} \
        --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE} \
        --upsert

    echo "=== Deploying Principal ==="
    (
        cd ${WORK_TMPDIR}/principal
        kustomize edit set namespace ${ARGOCD_PRINCIPAL_NAMESPACE}
        kustomize edit set image argocd-agent=${LOCAL_IMAGE}
        sed -i '' \
            -e "s/  principal.allowed-namespaces:.*/  principal.allowed-namespaces: \"agent-*\"/" \
            -e "s/  principal.namespace:.*/  principal.namespace: \"${ARGOCD_PRINCIPAL_NAMESPACE}\"/" \
            -e "s/  principal.listen.host:.*/  principal.listen.host: \"0.0.0.0\"/" \
            principal-params-cm.yaml
        cat >> kustomization.yaml <<PULLEOF

patches:
- target:
    kind: Deployment
    name: argocd-agent-principal
  patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/imagePullPolicy
      value: IfNotPresent

transformers:
- |-
  apiVersion: builtin
  kind: NamespaceTransformer
  metadata:
    name: principal-namespace-transformer
    namespace: ${ARGOCD_PRINCIPAL_NAMESPACE}
  setRoleBindingSubjects: allServiceAccounts
PULLEOF
        kustomize build . | kubectl --context ${HUB_CONTEXT} -n ${ARGOCD_PRINCIPAL_NAMESPACE} apply -f -
    )

    echo "-> Exposing principal as NodePort"
    kubectl patch svc argocd-agent-principal \
        -n ${ARGOCD_PRINCIPAL_NAMESPACE} \
        --context ${HUB_CONTEXT} \
        --patch '{"spec":{"type":"NodePort"}}'

    kubectl --context ${HUB_CONTEXT} -n ${ARGOCD_PRINCIPAL_NAMESPACE} \
        rollout status --watch --timeout=180s deployment argocd-agent-principal

    PRINCIPAL_NODE_PORT=$(kubectl get svc argocd-agent-principal \
        -n ${ARGOCD_PRINCIPAL_NAMESPACE} --context ${HUB_CONTEXT} \
        -o jsonpath='{.spec.ports[0].nodePort}')
    echo "  -> Principal NodePort: ${PRINCIPAL_NODE_PORT}"

    echo "=== Deploying Agents ==="
    AGENTS="agent-managed:${ARGOCD_MANAGED_NAMESPACE}:${MANAGED_CONTEXT}:managed agent-autonomous:${ARGOCD_AUTONOMOUS_NAMESPACE}:${AUTONOMOUS_CONTEXT}:autonomous"

    for agent_spec in ${AGENTS}; do
        IFS=":" read -r agent_name agent_ns agent_ctx agent_mode <<< "${agent_spec}"

        echo "-> Setting up ${agent_name} (${agent_mode} mode)"

        echo "  -> Creating agent configuration on principal"
        if ! ${AGENTCTL} agent inspect ${agent_name} \
            --principal-context ${HUB_CONTEXT} \
            --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE} >/dev/null 2>&1; then
            ${AGENTCTL} agent create ${agent_name} \
                --principal-context ${HUB_CONTEXT} \
                --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE} \
                --resource-proxy-server ${HUB_IP}:9090
        else
            echo "    -> Reusing existing agent configuration"
        fi

        echo "  -> Issuing agent client certificate"
        ${AGENTCTL} pki issue agent ${agent_name} \
            --principal-context ${HUB_CONTEXT} \
            --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE} \
            --agent-context ${agent_ctx} \
            --agent-namespace ${agent_ns} \
            --upsert

        echo "  -> Propagating CA to agent"
        ${AGENTCTL} pki propagate \
            --principal-context ${HUB_CONTEXT} \
            --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE} \
            --agent-context ${agent_ctx} \
            --agent-namespace ${agent_ns} -f

        echo "  -> Creating agent namespace on principal"
        kubectl create namespace ${agent_name} --context ${HUB_CONTEXT} 2>/dev/null || true

        echo "  -> Deploying agent"
        (
            cd ${WORK_TMPDIR}/agent
            kustomize edit set namespace ${agent_ns}
            kustomize edit set image argocd-agent=${LOCAL_IMAGE}
            sed -i '' \
                -e "s/  agent.mode:.*/  agent.mode: \"${agent_mode}\"/" \
                -e "s/  agent.creds:.*/  agent.creds: \"mtls:any\"/" \
                -e "s/  agent.server.address:.*/  agent.server.address: \"${HUB_IP}\"/" \
                -e "s/  agent.server.port:.*/  agent.server.port: \"${PRINCIPAL_NODE_PORT}\"/" \
                -e "s/  agent.namespace:.*/  agent.namespace: \"${agent_ns}\"/" \
                agent-params-cm.yaml
            cat >> kustomization.yaml <<PULLEOF

patches:
- target:
    kind: Deployment
    name: argocd-agent-agent
  patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/imagePullPolicy
      value: IfNotPresent

transformers:
- |-
  apiVersion: builtin
  kind: NamespaceTransformer
  metadata:
    name: agent-namespace-transformer
    namespace: ${agent_ns}
  setRoleBindingSubjects: allServiceAccounts
PULLEOF
            kustomize build . | kubectl --context ${agent_ctx} -n ${agent_ns} apply -f -
        )

        # Reset the agent kustomization for the next agent
        cp -a ${BASEPATH}/install/kubernetes/agent/* ${WORK_TMPDIR}/agent/

        echo "  -> Waiting for agent deployment"
        kubectl --context ${agent_ctx} -n ${agent_ns} \
            rollout status --watch --timeout=180s deployment argocd-agent-agent || true
    done

    echo "=== Deploying Test Applications ==="
    echo "-> Patching default AppProject on principal"
    kubectl patch appproject default -n ${ARGOCD_PRINCIPAL_NAMESPACE} \
        --context ${HUB_CONTEXT} --type='merge' \
        --patch='{"spec":{"sourceNamespaces":["*"],"destinations":[{"name":"*","namespace":"*","server":"*"}]}}' || true

    echo "-> Deploying managed guestbook app"
    kubectl apply -f ${SCRIPTPATH}/apps/managed-guestbook.yaml --context ${HUB_CONTEXT} || true

    echo "-> Deploying autonomous project and guestbook app"
    kubectl apply -f ${SCRIPTPATH}/apps/autonomous-project.yaml --context ${AUTONOMOUS_CONTEXT} || true
    kubectl apply -f ${SCRIPTPATH}/apps/autonomous-guestbook.yaml --context ${AUTONOMOUS_CONTEXT} || true

    echo "=== Verification ==="
    echo "-> Checking agent connections"
    sleep 10
    echo "  -> Managed agent logs:"
    kubectl logs -n ${ARGOCD_MANAGED_NAMESPACE} deployment/argocd-agent-agent \
        --context ${MANAGED_CONTEXT} --tail=5 2>/dev/null || echo "    (agent not ready yet)"
    echo "  -> Autonomous agent logs:"
    kubectl logs -n ${ARGOCD_AUTONOMOUS_NAMESPACE} deployment/argocd-agent-agent \
        --context ${AUTONOMOUS_CONTEXT} --tail=5 2>/dev/null || echo "    (agent not ready yet)"

    echo "-> Listing connected agents"
    ${AGENTCTL} agent list \
        --principal-context ${HUB_CONTEXT} \
        --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE} || true

    echo "=== ArgoCD UI ==="
    ADMIN_PASSWORD=$(kubectl -n ${ARGOCD_PRINCIPAL_NAMESPACE} get secret argocd-initial-admin-secret \
        --context ${HUB_CONTEXT} \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(not available)")

    echo ""
    echo "ArgoCD UI: https://localhost:8080"
    echo "Username:  admin"
    echo "Password:  ${ADMIN_PASSWORD}"
    echo ""
    echo "To start port-forward, run:"
    echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_PRINCIPAL_NAMESPACE} 8080:443 --context ${HUB_CONTEXT}"
    echo ""
    echo "=== Setup Complete ==="
}

do_delete() {
    echo "=== Deleting kind clusters ==="
    for cluster in ${HUB_CLUSTER_NAME} ${MANAGED_CLUSTER_NAME} ${AUTONOMOUS_CLUSTER_NAME}; do
        echo "  -> Deleting cluster ${cluster}"
        kind delete cluster --name ${cluster} 2>/dev/null || true
    done

    kubectl config delete-context ${HUB_CONTEXT} 2>/dev/null || true
    kubectl config delete-context ${MANAGED_CONTEXT} 2>/dev/null || true
    kubectl config delete-context ${AUTONOMOUS_CONTEXT} 2>/dev/null || true

    echo "=== Cleanup Complete ==="
}

do_status() {
    echo "=== Kind Clusters ==="
    kind get clusters 2>/dev/null || echo "(none)"

    for ctx_name in "${HUB_CONTEXT}:${ARGOCD_PRINCIPAL_NAMESPACE}" "${MANAGED_CONTEXT}:${ARGOCD_MANAGED_NAMESPACE}" "${AUTONOMOUS_CONTEXT}:${ARGOCD_AUTONOMOUS_NAMESPACE}"; do
        IFS=":" read -r ctx ns <<< "${ctx_name}"
        echo ""
        echo "=== ${ctx} (ns: ${ns}) ==="
        if kubectl --context ${ctx} get nodes >/dev/null 2>&1; then
            kubectl --context ${ctx} get pods -n ${ns} 2>/dev/null || echo "(no pods)"
        else
            echo "(cluster not reachable)"
        fi
    done

    echo ""
    echo "=== Connected Agents ==="
    ${AGENTCTL} agent list \
        --principal-context ${HUB_CONTEXT} \
        --principal-namespace ${ARGOCD_PRINCIPAL_NAMESPACE} 2>/dev/null || echo "(principal not reachable)"
}

case "$action" in
create)
    do_create
    ;;
delete)
    do_delete
    ;;
status)
    do_status
    ;;
*)
    echo "USAGE: $0 <create|delete|status>" >&2
    exit 1
    ;;
esac
