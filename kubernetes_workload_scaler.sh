#!/bin/sh


# set -x


# Stop script if missing dependency
required_commands="kubectl"
for command in $required_commands; do
    if [ -z "$(command -v $command)" ]; then
        echo "error: required command not found: $command"
        exit
    fi
done


# Execution help message
# Usage: usage
usage() {
    echo "Kubernetes workload scaler"
    echo "  Scale down/up all pods from all namespaces"
    echo "  This script intends to be used directly from Kubernetes cronjobs"
    echo ""
    echo "Usages:"
    echo "  $0 --up         scale up all pods on the cluster"
    echo "  $0 --down       scale down all pods on the cluster"

    exit 1
}


# Get current datetime
# Usage: get_now
get_now() {
    date '+%Y-%m-%d %H:%M:%S'
}


# Sanitize logs format
# Usage: write_log <message>
write_log() {
    local message=$1

    echo -n "[$(get_now)] $message\n"
}


# List all namespaces + optionally filter them from exclusion list
# Usages:
#   list_namespaces
#   list_namespaces "<namespace_excluded_1> <namespaces_excluded_2> <namespaces_excluded_3> etc..."
list_namespaces() {
    local namespaces_excluded=$1
    local namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')"

    for n in $namespaces; do
        if ! echo "$namespaces_excluded" | grep -qw "$n"; then
            filtered_namespaces="$filtered_namespaces $n"
        fi
    done

    echo $filtered_namespaces
}


# List all statefulsets in a given namespace
# Usage: list_ns_statefusets <namespace>
list_ns_statefusets() {
    local ns=$1

    # <statefulset_name>=<replicas>
   kubectl -n $ns get statefulsets -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas}{"\n"}{end}'
}


# List all deployments in a given namespace
# Usage: list_ns_deployments <namespace>
list_ns_deployments() {
    local ns=$1

    # <deployment_name>=<replicas>
    kubectl -n $ns get deployments -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas}{"\n"}{end}'
}


# List all Cloudnative-PG clusters in a given namespace
# Usage: list_ns_cnpg_clusters <namespace>
list_ns_cnpg_clusters() {
    local ns=$1

    # NOTE: the format used to store cnpg_clusters is not the same as statefulsets & depployments because we can't manually scale the replicas

    # <cluster_namespace>/<cluster_name>
    kubectl -n $ns get clusters -o jsonpath='{.items[*].metadata.name}'
}


# Store anything to a given configmap
# Usage: store_to_configmap <namespace> <configmap> <key> <value>
store_to_configmap() {
    local ns=$1
    local cm=$2
    local key=$3
    local value=$4

    # Silently create configmap if not exists
    kubectl -n $ns create configmap $cm --dry-run=client -o yaml | kubectl apply -f -

    kubectl -n $ns patch configmap $cm --type merge -p "{\"data\":{\"$key\":\"$value\"}}"
}


# Delete a given configmap
# Usage: delete_configmap <namespace> <name>
delete_configmap() {
    local ns=$1
    local cm=$2

    write_log "Deleting configmap $ns/$cm..."
    kubectl -n $ns delete configmap $cm --ignore-not-found=true
}


# Scale replicas of a given statefulset
# Usage: scale_statefulset <namespace> <item> <replicas>
scale_statefulset() {
    local ns=$1
    local item=$2
    local replicas=$3

    write_log "Scaling statefulset $ns/$item to $replicas..."
    kubectl -n $ns scale --replicas $replicas statefulset $item
}


# Scale replicas of a given deployment
# Usage: scale_deployment <namespace> <item> <replicas>
scale_deployment() {
    local ns=$1
    local item=$2
    local replicas=$3

    write_log "Scaling deployment $ns/$item to $replicas..."
    kubectl -n $ns scale --replicas $replicas deployment $item
}


# Scale down a given Cloudnative-PG cluster
# CNPG clusters are not deployments nor statefulsets, they are pods triggered by the Cloudnative-PG operator
# - if the operator is up   => 'spec.instances' of the cluster will be fullfilled
# - if the operator is down => the pod can be killed, it will not restart
#
# Usage: scale_down_cnpg_cluster <namespace> <item> <replicas>
scale_down_cnpg_cluster() {
    local ns=$1
    local item=$2

    write_log "Scaling cnpg_cluster $ns/$item to 0..."
    kubectl -n $ns delete pods -l cnpg.io/cluster=$item
}


# Save current workload state to configmap
# Usage: save_workload <configmap_namespace> <configmap_name>
save_workload() {
    local cm_ns=$1
    local cm_name=$2

    # Delete old data
    delete_configmap $cm_ns $cm_name

    namespaces="$(list_namespaces 'calico-system gatekeeper-system kube-node-lease kube-public kube-system tigera-operator')"
    write_log "Retrieving all workloads..."
    for ns in $namespaces; do
        local i

        local statefulsets="$(list_ns_statefusets $ns)"
        for i in $statefulsets; do
            path="$(echo "$ns/$i")"
            write_log "statefulset:  $path"

            statefulset_paths="$(echo $path $statefulset_paths)"
        done

        local deployments="$(list_ns_deployments $ns)"
        for i in $deployments; do
            path="$(echo "$ns/$i")"
            write_log "deployment:   $path"

            deployment_paths="$(echo $path $deployment_paths)"
        done

        local cnpg_clusters="$(list_ns_cnpg_clusters $ns)"
        for i in $cnpg_clusters; do
            path="$(echo "$ns/$i")"
            write_log "cnpg_cluster: $path"

            cnpg_cluster_paths="$(echo $path $cnpg_cluster_paths)"
        done
    done

    write_log "Saving workloads states to configmap $cm_ns/$cm_name..."
    store_to_configmap $cm_ns $cm_name 'statefulsets' "$statefulset_paths"
    store_to_configmap $cm_ns $cm_name 'deployments' "$deployment_paths"
    store_to_configmap $cm_ns $cm_name 'cnpg_clusters' "$cnpg_cluster_paths"

    # Ensure the configmap is created
    sleep 3
}


# Get workload saved in configmap from last scale down
# Usage: get_saved_workload <configmap_namespace> <configmap> <workload_type (statefulset/deployment/cnpg_cluster)>
get_saved_workload() {
    local cm_ns=$1
    local cm_name=$2
    local workload_type=$3

    kubectl -n $cm_ns get cm $cm_name -o jsonpath="{.data.$workload_type}"
}


# Str manipulation to get the workload namespace from the saved configmap
# Usage: get_saved_workload_ns <workload_path>
get_saved_workload_ns() {
    local workload_path=$1

    # get NAMESPACE/name=replicas
    echo $workload_path | cut -d/ -f1
}


# Str manipulation to get the workload namespace from the saved configmap
# Usage: get_saved_workload_name <workload_path>
get_saved_workload_name() {
    local workload_path=$1

    # get namespace/NAME=replicas
    echo $workload_path | cut -d/ -f2 | cut -d= -f1
}


# Str manipulation to get the workload namespace from the saved configmap
# Usage: get_saved_workload_replicas <workload_path>
get_saved_workload_replicas() {
    local workload_path=$1

    # get namespace/name=REPLICAS
    echo $workload_path | cut -d= -f2
}


# Scale down job (reading workload to scale from configmap)
# Usage: scale_down <configmap_namespace> <configmap>
scale_down() {
    local cm_ns=$1
    local cm_name=$2

    write_log "Writing scale_down job timestamp to $cm_ns/$cm_name..."
    store_to_configmap $cm_ns $cm_name 'scale_down_job_timestamp' "$(get_now)"

    write_log "Reading all workloads to scale down from $cm_ns/$cm_name..."
    local statefulsets="$(get_saved_workload $cm_ns $cm_name 'statefulsets')"
    local deployments="$(get_saved_workload $cm_ns $cm_name 'deployments')"
    local cnpg_clusters="$(get_saved_workload $cm_ns $cm_name 'cnpg_clusters')"

    write_log "Running scale down job..."
    local workload
    local workload_ns
    local workload_name
    local workload_replicas

    write_log "=> Scaling down statefulsets..."
    for workload in $statefulsets; do
        workload_ns="$(get_saved_workload_ns $workload)"
        workload_name="$(get_saved_workload_name $workload)"

        scale_statefulset $workload_ns $workload_name "0"
    done

    write_log "=> Scaling down deployments..."
    for workload in $deployments; do
        workload_ns="$(get_saved_workload_ns $workload)"
        workload_name="$(get_saved_workload_name $workload)"

        scale_deployment $workload_ns $workload_name "0"
    done

    # Must be done after Cloudnative-PG operator deployment scale down, otherwise CNPG clusters will respawn
    write_log "=> Scaling down cnpg_clusters..."
    for workload in $cnpg_clusters; do
        workload_ns="$(get_saved_workload_ns $workload)"
        workload_name="$(get_saved_workload_name $workload)"

        scale_down_cnpg_cluster $workload_ns $workload_name
    done
}


# Scale up job (reading workload to scale from configmap)
# Usage: scale_up <configmap_namespace> <configmap>
scale_up() {
    local cm_ns=$1
    local cm_name=$2

    write_log "Reading all workloads to scale up from $cm_ns/$cm_name..."
    local statefulsets="$(get_saved_workload $cm_ns $cm_name 'statefulsets')"
    local deployments="$(get_saved_workload $cm_ns $cm_name 'deployments')"
    local cnpg_clusters="$(get_saved_workload $cm_ns $cm_name 'cnpg_clusters')"

    write_log "Running scale up job..."

    # NOTE: cnpg_clusters are scaled up by the Cloudnative-PG operator, don't need to do it from the script

    write_log "=> Scaling up deployments..."
    for workload in $deployments; do
        workload_ns="$(get_saved_workload_ns $workload)"
        workload_name="$(get_saved_workload_name $workload)"
        workload_replicas="$(get_saved_workload_replicas $workload)"

        scale_deployment $workload_ns $workload_name $workload_replicas
    done

    write_log "=> Scaling up statefulsets..."
    for workload in $statefulsets; do
        workload_ns="$(get_saved_workload_ns $workload)"
        workload_name="$(get_saved_workload_name $workload)"
        workload_replicas="$(get_saved_workload_replicas $workload)"

        scale_statefulset $workload_ns $workload_name $workload_replicas
    done
}


if [ -z "$KWS_CONFIGMAP_NAMESPACE" ]; then
    KWS_CONFIGMAP_NAMESPACE='default'
fi

if [ -z "$KWS_CONFIGMAP_NAME" ]; then
    KWS_CONFIGMAP_NAME='kws-cache'
fi


case "$1" in
    --down)
        save_workload $KWS_CONFIGMAP_NAMESPACE $KWS_CONFIGMAP_NAME
        scale_down $KWS_CONFIGMAP_NAMESPACE $KWS_CONFIGMAP_NAME
        ;;
    --up)
        scale_up $KWS_CONFIGMAP_NAMESPACE $KWS_CONFIGMAP_NAME
        ;;
    *)
        usage
        ;;
esac


exit
