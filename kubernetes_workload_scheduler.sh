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
    echo "  This script intends to be used directly from scale-up/down Kubernetes cronjobs"
    echo ""
    echo "Usages:"
    echo "  $0 --up         scale up all pods on the cluster"
    echo "  $0 --down       scale down all pods on the cluster"

    exit 1
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

    # <cluster_name>=<replicas>
    kubectl -n $ns get clusters -o jsonpath='{range .items[*]}{.metadata.name}={.spec.instances}{"\n"}{end}'
}


# Store anything to a given configmap
# Usage: store_to_configmap <namespace> <configmap> <key> <value>
store_to_configmap() {
    local ns=$1
    local cm=$2
    local key=$3
    local value=$4

    # if [ ! "$(kubectl -n $ns get configmap $cm)" ]; then
    #     kubectl -n $ns create configmap $cm
    # fi

    # Silently create configmap if not exists
    kubectl -n $ns create configmap $cm --dry-run=client -o yaml | kubectl apply -f -

    kubectl -n $ns patch configmap $cm --type merge -p "{\"data\":{\"$key\":\"$value\"}}"
}


# # Get a given configmap
# # Usage: get_configmap <namespace> <name>
# get_configmap() {
#     local ns=$1
#     local cm=$2

#     kubectl -n $ns get configmap $cm
# }


# Delete a given configmap
# Usage: delete_configmap <namespace> <name>
delete_configmap() {
    local ns=$1
    local cm=$2

    echo "Deleting configmap $ns/$cm..."
    kubectl -n $ns delete configmap $cm --ignore-not-found=true
}


# Scale replicas of a given statefulset
# Usage: scale_statefulset <namespace> <item> <replicas>
scale_statefulset() {
    local ns=$1
    local item=$2
    local replicas=$3

    echo "Scaling statefulset $ns/$item to $replicas..."
    kubectl -n $ns scale --replicas $replicas statefulset $item
}


# Scale replicas of a given deployment
# Usage: scale_deployment <namespace> <item> <replicas>
scale_deployment() {
    local ns=$1
    local item=$2
    local replicas=$3

    echo "Scaling deployment $ns/$item to $replicas..."
    kubectl -n $ns scale --replicas $replicas deployment $item
}



# Scale replicas of a given Cloudnative-PG cluster
# Usage: scale_cnpg_cluster <namespace> <item> <replicas>
scale_cnpg_cluster() {
    local ns=$1
    local item=$2
    local replicas=$3

    echo "Scaling cnpg_cluster $ns/$item to $replicas..."
    kubectl -n $ns patch cluster $item --type='json' -p="[{"op": "replace", "path": "/spec/instances", "value": $replicas}]"
}



# Save current workload state to configmap
# Usage: save_workload <configmap_namespace> <configmap_name>
save_workload() {
    local cm_ns=$1
    local cm_name=$2

    # Delete old data
    delete_configmap $cm_ns $cm_name

    namespaces="$(list_namespaces 'calico-system gatekeeper-system kube-node-lease kube-public kube-system tigera-operator')"
    echo "\nRetrieving all workloads..."
    for ns in $namespaces; do
        statefulsets="$(list_ns_statefusets $ns)"
        for i in $statefulsets; do
            path="$(echo "$ns/$i")"
            echo "statefulset:  $path"

            statefulset_paths="$(echo $path $statefulset_paths)"
        done

        deployments="$(list_ns_deployments $ns)"
        for i in $deployments; do
            path="$(echo "$ns/$i")"
            echo "deployment:   $path"

            deployment_paths="$(echo $path $deployment_paths)"
        done

        cnpg_clusters="$(list_ns_cnpg_clusters $ns)"
        for i in $cnpg_clusters; do
            path="$(echo "$ns/$i")"
            echo "cnpg_cluster: $path"

            cnpg_cluster_paths="$(echo $path $cnpg_cluster_paths)"
        done
    done

    echo "\nSaving workloads states to configmap $cm_ns/$cm_name..."
    store_to_configmap $cm_ns $cm_name 'statefulsets' "$statefulset_paths"
    store_to_configmap $cm_ns $cm_name 'deployments' "$deployment_paths"
    store_to_configmap $cm_ns $cm_name 'cnpg_clusters' "$cnpg_cluster_paths"
}


CM_NS='default'
CM_NAME='workload-scaler-replicas'
save_workload $CM_NS $CM_NAME


# cm_ns='default'
# cm_name='workload-scaler-replicas'
# delete_configmap $cm_ns $cm_name


# namespaces="$(list_namespaces 'calico-system gatekeeper-system kube-node-lease kube-public kube-system tigera-operator')"
# echo "\nRetrieving all workloads..."
# for ns in $namespaces; do
#     statefulsets="$(list_ns_statefusets $ns)"
#     for i in $statefulsets; do
#         path="$(echo "$ns/$i")"
#         echo "statefulset:  $path"

#         statefulset_paths="$(echo $path $statefulset_paths)"
#     done

#     deployments="$(list_ns_deployments $ns)"
#     for i in $deployments; do
#         path="$(echo "$ns/$i")"
#         echo "deployment:   $path"

#         deployment_paths="$(echo $path $deployment_paths)"
#     done

#     cnpg_clusters="$(list_ns_cnpg_clusters $ns)"
#     for i in $cnpg_clusters; do
#         path="$(echo "$ns/$i")"
#         echo "cnpg_cluster: $path"

#         cnpg_cluster_paths="$(echo $path $cnpg_cluster_paths)"
#     done
# done

# echo "\nSaving workloads states to configmap $cm_ns/$cm_name..."
# store_to_configmap $cm_ns $cm_name 'statefulsets' "$statefulset_paths"
# store_to_configmap $cm_ns $cm_name 'deployments' "$deployment_paths"
# store_to_configmap $cm_ns $


# for ns in $namespaces; do
#     statefulsets="$(list_ns_statefusets $ns)"
#     for i in $statefulsets; do
#         path="$(echo "$ns/$i")"
#         echo $path

#         statefulset_paths="$(echo $path $statefulset_paths)"
#     done
# done
# store_to_configmap $cm_ns $cm_name 'statefulsets' $statefulset_paths


# for ns in $namespaces; do
#     deployments="$(list_ns_deployments $ns)"
#     for i in $deployments; do
#         path="$(echo "$ns/$i")"
#         echo $path

#         deployment_paths="$(echo $path $deployment_paths)"
#     done
# done
# store_to_configmap $cm_ns $cm_name 'deployments' $deployment_paths


# for ns in $namespaces; do
#     cnpg_clusters="$(list_ns_cnpg_clusters $ns)"
#     for i in $cnpg_clusters; do
#         path="$(echo "$ns/$i")"
#         echo $path

#         cnpg_cluster_paths="$(echo $path $cnpg_cluster_paths)"
#     done
# done
# store_to_configmap $cm_ns $cm_name 'cnpg_clusters' $cnpg_cluster_paths



# # Scale down a given statefulset
# # Usage: scale_down_statefulset <namespace> <item>
# scale_down_statefulset() {
#     local ns=$1
#     local item=$2

#     scale_statefulset $ns $item 0
# }


# # Scale down a given deployment
# # Usage: scale_down_deployment <namespace> <item>
# scale_down_deployment() {
#     local ns=$1
#     local item=$2

#     scale_deployment $ns $item 0
# }



# # Scale down a given Cloudnative-PG cluster
# # Usage: scale_down_cnpg_cluster <namespace> <item>
# scale_down_cnpg_cluster() {
#     local ns=$1
#     local item=$2

#     scale_cnpg_cluster $ns $item 0
# }


# # Scale up a given statefulset
# # Usage: scale_up_statefulset <namespace> <item>
# scale_up_statefulset() {
#     local ns=$1
#     local item=$2
#     local replicas=$3

#     scale_statefulset $ns $item $replicas
# }


# # Scale up a given deployment
# # Usage: scale_up_deployment <namespace> <item>
# scale_up_deployment() {
#     local ns=$1
#     local item=$2
#     local replicas=$3

#     scale_deployment $ns $item $replicas
# }



# # Scale up a given Cloudnative-PG cluster
# # Usage: scale_up_cnpg_cluster <namespace> <item>
# scale_up_cnpg_cluster() {
#     local ns=$1
#     local item=$2
#     local replicas=$3

#     scale_cnpg_cluster $ns $item $replicas
# }


exit
