__pod_launched() {
    NAMESPACE=$1
    POD_NAME=$2
    date
    output=$(__kubekind -n $NAMESPACE get po -o jsonpath='{.items[*].metadata.name}' | grep $POD_NAME)
    if [[ $? != 0 ]]; then
        echo "Waiting for $POD_NAME pod to be launched in $NAMESPACE ..."
        return 1
    else
        echo "$POD_NAME pod has been launched into $NAMESPACE namespace"
        return 0
    fi
}

__wait_for_pod_launched() {
    NAMESPACE=$1
    POD_NAME=$2
    while true; do __pod_launched "$NAMESPACE" "$POD_NAME" && break || sleep 2; done
}

__pods_are_ready() {
    NAMESPACE=$1
    date
    # reason == "Completed" means a job
    output=$(__kubekind -n $NAMESPACE get po -o jsonpath='{.items[*].status.containerStatuses[?(@.ready!=true)]}' | jq '.state.terminated | select(.reason!="Completed")')
    if [[ $? != 0 ]]; then
        echo "Failed to check if pods in $NAMESPACE namespace are ready, terminate if needed ..."
        return 1
    elif [[ $output ]]; then
        echo $output
        echo "Waiting for all pods in $NAMESPACE namespace to be ready ..."
        return 1
    else
        echo "All pods in $NAMESPACE namespace are ready"
        return 0
    fi
}

__wait_for_pods_ready() {
    NAMESPACE=$1
    while true; do __pods_are_ready "$NAMESPACE" && break || sleep 2; done
}

__install_and_wait_for_techs() {
	__install_kafka
	__install_kafdrop
	__install_redis

	__wait_for_pod_launched "kafkacluster" "kafka-cluster-kafka-0"
	__wait_for_pod_launched "redis-sentinel" "redis-poc-node-0"
	__wait_for_pods_ready "kafkacluster"
	__wait_for_pods_ready "redis-sentinel"
}

SYSTEM_TEST_POD_SPEC=$(cat <<EOF
{
  "spec": {
    "containers": [
      {
        "name": "systemtests-pod",
        "image": "kind-local/jre11robot:1.0.0",
        "volumeMounts": [
          {
            "mountPath": "/systemtests",
            "name": "testmnt"
          }
        ]
      }
    ],
    "volumes": [
      {
        "name": "testmnt",
        "hostPath": {
          "path": "/kind-systemtests",
          "type": "DirectoryOrCreate"
        }
      }
    ]
  }
}
EOF
)

__override_system_test_pod_spec() {
	COMMAND=$1
	SPEC=$(echo $SYSTEM_TEST_POD_SPEC | jq -c ".spec.containers[0].command=[\"bash\", \"-c\", \"$COMMAND\"]")
	echo $SPEC
}

__configure_pod_user() {
	D_UID=$(id -u)
	D_GID=$(id -g)
	D_USER=$(whoami)
	echo "addgroup --gid $D_GID $D_USER && adduser --uid $D_UID --gid $D_GID --disabled-password --gecos '' $D_USER && runuser -u $D_USER"
}

__kubekind() {
	if [ -z "$GITLAB_CI" ]; then
		KUBECONFIG=$PIPELINE_CLUSTER/kind_kube_config kubectl "$@"
	else
		kubectl "$@"
	fi
}

__helm() {
	if [ -z "$GITLAB_CI" ]; then
		KUBECONFIG=$PIPELINE_CLUSTER/kind_kube_config helm "$@"
	else
		helm "$@"
	fi
}

__kill_integration_tests_containers() {
	docker kill robot || echo failed to kill robot container
	docker kill sbc || echo failed to kill sbc container
}

run_tests() {
	cp /etc/hosts systemtests/.
	cp /root/.kube/config systemtests/.
	# -v /root/.kube:/.kube always result in an empty folder inside the container
	timeout 20 docker run --name robot --rm --network host --entrypoint /bin/bash \
		-v $(pwd)/systemtests:/systemtests kind-local/jre11robot:1.0.0 \
		-c "cp /systemtests/hosts /etc/hosts && robot integration-tests.robot"
	trap __kill_integration_tests_containers EXIT
}

