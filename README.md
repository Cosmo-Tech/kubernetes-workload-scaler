# Kubernetes workload scaler

Cloud agnostic Kubernetes cluster start/stop tool

* Scale up/down all pods from all namespaces
* Designed to work in Kubernetes cronjob (1 job for scale up, 1 job for scale down)
* Cloud agnostic (because it works directly inside the cluster)
* Work with current kubectl context
* 100% POSIX Shell

## Requirements
* A shell
* [kubectl](https://kubernetes.io/fr/docs/tasks/tools/install-kubectl/)
* A working Kubernetes cluster

> [!NOTE]
> This tool intends to start/stop Kubernetes clusters by scaling its workload.
> It means nodes pools you want to scale must be configured with minimal nodes to 0.

## Usages
### CLI
* Scale up
    ```
    ./kubernetes-workload-scaler.sh --up
    ```

* Scale down
    ```
    ./kubernetes-workload-scaler.sh --down
    ```

### Docker
* Scale up
    ```
    todo
    ```

* Scale down
    ```
    todo
    ```


## Developpers
> *workloads = statefulsets + deployments + cnpg_clusters (=pods)

### Workflows
#### Scale down
1. List all workloads found in all namespaces
2. Store this list to a configmap
3. Scale down the workload listed in the configmap

#### Scale up
> :warning: Can run only after a scale down
1. Read the configmap created during scale down
2. Scale up the workload from the configmap

<br>
<br>

Made with :heart: by Cosmo Tech DevOps team
