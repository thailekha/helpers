#!/usr/bin/env sh

set -ex

PIPELINE_CLUSTER_PATH=$(pwd)
INTERFERENCE_CONTROLLER_PATH=$(realpath `pwd`/..)
IC_PATH="$INTERFERENCE_CONTROLLER_PATH/ic"
IC_NAMESPACE="local-ic"
CACHED_JDK_IMAGE="thailekha/ic-jdk-cache:1.0.0"

#######################################
## debug utils
#######################################

launch_ubuntu_pod() {
	__kubekind run ubuntu-pod --rm -ti --restart=Never --image=ubuntu -- bash -c "apt-get update && apt-get install -y dnsutils && bash"
}

#######################################
## k8s helpers
#######################################

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

#######################################
## techs provisioning
#######################################

__install_kafka() {
	# ful guide on deploying strimzi at https://strimzi.io/docs/operators/latest/full/deploying.html#deploying-cluster-operator-helm-chart-str
	# note that in strimzi, kafka operator means the same as cluster operator,
	# and it contains other types of operators within like entityOperator, topicOperator, userOperator
	echo "Installing Kafka Strimzi"
	__helm repo add strimzi http://strimzi.io/charts/
	__helm install strimzi-kafka strimzi/strimzi-kafka-operator --namespace "$IC_NAMESPACE"
	__kubekind --namespace "$IC_NAMESPACE" apply -f helm-values/kafka.yaml
	__kubekind --namespace "$IC_NAMESPACE" apply -f helm-values/kafka-topics.yaml
}

__install_kafdrop() {
	echo "Install KafDrop UI"
    __kubekind create namespace kafdrop
    __helm upgrade -i kafdrop ./kafdrop --set image.tag=3.27.0 --namespace kafdrop \
        --set kafka.brokerConnect="kafka-cluster-kafka-bootstrap.$IC_NAMESPACE.svc.cluster.local:9092" \
        --set server.servlet.contextPath="/" \
        --set jvm.opts="-Xms32M -Xmx64M"
}

__install_grafana() {
    echo "Installing Grafana"
    # __helm repo add grafana https://grafana.github.io/helm-charts
    __helm install --namespace "$IC_NAMESPACE" grafana grafana/grafana \
        --set adminPassword='admin' \
        --values helm-values/grafana-datasources.yaml
}

__install_redis() {
 	echo "Installing Redis Sentinel"
 	__kubekind create namespace redis-sentinel
 	__helm repo add bitnami https://charts.bitnami.com/bitnami
 	__helm install redis-poc bitnami/redis --namespace redis-sentinel --values helm-values/redis.yaml
}

__install_jaeger() {
 	echo "Installing Jaeger"
	__helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
 	__helm --namespace "$IC_NAMESPACE" install my-jaeger jaegertracing/jaeger-operator
	__kubekind --namespace "$IC_NAMESPACE" apply -f helm-values/jaeger.yaml
}

__install_and_wait_for_techs() {
	__kubekind create namespace "$IC_NAMESPACE"
	__install_kafka
	if [ -z "$GITLAB_CI" ]; then
		__install_kafdrop
	fi
	__install_redis
	# __install_grafana
	# __install_jaeger

	__wait_for_pod_launched "$IC_NAMESPACE" "kafka-cluster-kafka-0"
	__wait_for_pod_launched "redis-sentinel" "redis-poc-node-0"
	__wait_for_pods_ready "$IC_NAMESPACE"
	__wait_for_pods_ready "redis-sentinel"
}

uninstall_techs() {
	__kubekind delete namespace kafdrop || echo Could not delete kafdrop namespace
	__kubekind delete namespace redis-sentinel || echo Could not delete redis-sentinel namespace
	__kubekind delete namespace "$IC_NAMESPACE" || echo Could not delete "$IC_NAMESPACE" namespace
}

#######################################
## kind cluster tasks
#######################################

__prepull_images() {
	KIND_CONTAINER_ID=$(docker ps | grep kindest/node | awk '{ print $1 }')
	docker cp "$PIPELINE_CLUSTER_PATH/kind-prepull-images.sh" "$KIND_CONTAINER_ID:/."
	docker exec $KIND_CONTAINER_ID bash kind-prepull-images.sh
}

__kubekind() {
	if [ -z "$GITLAB_CI" ]; then
		KUBECONFIG=$PIPELINE_CLUSTER_PATH/kind_kube_config kubectl "$@"
	else
		kubectl "$@"
	fi
}

__k9skind() {
	if [ -z "$GITLAB_CI" ]; then
		KUBECONFIG=$PIPELINE_CLUSTER_PATH/kind_kube_config k9s -A "$@"
	else
		kubectl "$@"
	fi
}

__helm() {
	if [ -z "$GITLAB_CI" ]; then
		KUBECONFIG=$PIPELINE_CLUSTER_PATH/kind_kube_config helm "$@"
	else
		helm "$@"
	fi
}

delete_cluster() {
	kind delete cluster || echo not created
}

__create_cluster() {
	delete_cluster
	cp helm-values/kind.yaml /tmp/kind-config.yaml
	rm -rf ic-mount || echo removed
	mkdir ic-mount
	IC_MOUNT_PATH=$(realpath `pwd`/ic-mount)
	sed -i -E -e "s?MODIFY_THIS_WITH_SED?$IC_MOUNT_PATH?" /tmp/kind-config.yaml
	cat /tmp/kind-config.yaml
	if [ -z "$GITLAB_CI" ]; then
		kind create cluster --config=/tmp/kind-config.yaml --kubeconfig kind_kube_config
		ALIAS_KIND="alias kubekind=\"KUBECONFIG=$(pwd)/kind_kube_config kubectl\""
		ALIAS_K9S="alias k9skind=\"KUBECONFIG=$(pwd)/kind_kube_config k9s -A\""
		grep -qxF "$ALIAS_KIND" ~/.bashrc || echo "$ALIAS_KIND" >> ~/.bashrc
		grep -qxF "$ALIAS_K9S" ~/.bashrc || echo "$ALIAS_K9S" >> ~/.bashrc
		cat "$PIPELINE_CLUSTER_PATH/kind_kube_config"
	else
		kind create cluster --config=/tmp/kind-config.yaml
		sed -i -E -e 's/localhost|0\.0\.0\.0|127\.0\.0\.1/docker/g' "$HOME/.kube/config"
		cat "$HOME/.kube/config"
	fi
	rm /tmp/kind-config.yaml
}

__wait_for_ready_node() {
	until __kubekind get nodes | grep -m 1 " Ready "; do date; echo "Waiting for KinD cluster nodes to be ready ..."; sleep 2; done
}

build_push_ic_docker_image() {
	docker build -t thailekha/ic-docker:1.0.0 - < "$PIPELINE_CLUSTER_PATH/Dockerfiles/IcPipeline"
	docker push thailekha/ic-docker:1.0.0
}

list_images() {
	__kubekind get pods --all-namespaces -o jsonpath="{..image}" |\
	tr -s '[[:space:]]' '\n' |\
	sort |\
	uniq
}

import_image_to_kind() {
	kind load docker-image "$1"
}

build_gateway_image() {
	cd $IC_PATH && ./gradlew gateway:installDist
	cd $INTERFERENCE_CONTROLLER_PATH
	mkdir -p gradle-cache
	rsync -a "$HOME/.gradle/" gradle-cache/
	docker build -t eng-docker-registry.sedsystems.ca/ic-gateway:0.0.1 -f $PIPELINE_CLUSTER_PATH/Dockerfiles/gateway .
	cd $PIPELINE_CLUSTER_PATH
}

test_gateway_image() {
	# build_gateway_image
	# import_image_to_kind eng-docker-registry.sedsystems.ca/ic-gateway:0.0.1
	__kubekind apply -f helm-values/configmap.yaml
	__kubekind apply -f helm-values/gateway.yaml
}

reset_demo_gateway_image() {
	__kubekind delete -f helm-values/configmap.yaml
	__kubekind delete -f helm-values/gateway.yaml
	# docker rmi eng-docker-registry.sedsystems.ca/ic-gateway:0.0.1
	# docker rmi eng-docker-registry.sedsystems.ca/ic:0.0.1
}

systemtests_cluster() {
	__create_cluster
	__prepull_images
	__wait_for_ready_node
	__install_and_wait_for_techs
}

#######################################
## IC codebase helpers
#######################################

# Example of using gradle cache if needed later on
# https://github.com/olavloite/spannerclient/blob/1ce4fe7a7c535b62f1f9c1a8185f8f875fd69b06/bin/run-tests.sh
cache_push_ic_openjdk_image() {
	docker run --name ic-compiler -v "$PIPELINE_CLUSTER_PATH/../ic:/ic" -w /ic openjdk:11 /bin/bash -c "./gradlew build --rerun-tasks && ./gradlew install"
	docker commit ic-compiler "$CACHED_JDK_IMAGE"
	docker push "$CACHED_JDK_IMAGE"
}

__compile_binary_pipeline() {
	docker run -v "$PIPELINE_CLUSTER_PATH/../ic:/ic" -w /ic "$CACHED_JDK_IMAGE" /bin/bash -c "$(__configure_pod_user) ./gradlew install"
}

__binary_ic() {
	cd "$PIPELINE_CLUSTER_PATH/../ic/"
	./gradlew install
	cd -
	rsync -av "$PIPELINE_CLUSTER_PATH/../ic/" ./ic-mount/
}

#######################################
## Launch pods and containers
#######################################

__configure_pod_user() {
	if [ -z "$GITLAB_CI" ]; then
		D_UID=$(id -u)
		D_GID=$(id -g)
		D_USER=$(whoami)
		echo "addgroup --gid $D_GID $D_USER && adduser --uid $D_UID --gid $D_GID --disabled-password --gecos '' $D_USER && runuser -u $D_USER --"
	else
		echo ""
	fi
}

POD_SPEC=$(cat <<EOF
{
  "spec": {
    "containers": [
      {
        "name": "name",
        "image": "thailekha/ic-jdk-cache:1.0.0",
        "env": [
          {
          	"name": "JAEGER_SERVICE_NAME",
          	"value": "ic-kafka"
          },
          {
          	"name": "JAEGER_AGENT_HOST",
          	"value": "my-jaeger-agent"
          },
          {
          	"name": "JAEGER_SAMPLER_TYPE",
          	"value": "const"
          },
          {
          	"name": "JAEGER_SAMPLER_PARAM",
          	"value": "1"
          },
          {
          	"name": "IN_CLUSTER",
          	"value": "true"
          }
        ],
        "volumeMounts": [
          {
            "mountPath": "/ic",
            "name": "testmnt"
          }
        ]
      }
    ],
    "volumes": [
      {
        "name": "testmnt",
        "hostPath": {
          "path": "/kind-ic-mount",
          "type": "DirectoryOrCreate"
        }
      }
    ]
  }
}
EOF
)

__override_pod_spec() {
	COMMAND=$1
	SPEC=$(echo $POD_SPEC | jq -c ".spec.containers[0].command=[\"bash\", \"-c\", \"$COMMAND\"]")
	echo $SPEC
}

run_sbc_pod() {
	__binary_ic
	SPEC=$(__override_pod_spec "$(__configure_pod_user) /ic/sbc/build/install/sbc/bin/sbc")
	__kubekind -n "$IC_NAMESPACE" run sbc-pod --rm --attach --restart=Never --image="$CACHED_JDK_IMAGE" --overrides="$SPEC"
}

__run_sbc_container() {
	__binary_ic
	docker run -d --name sbc --rm --network host -v "$PIPELINE_CLUSTER_PATH/ic-mount:/ic" \
		"$CACHED_JDK_IMAGE" /bin/bash -c "$(__configure_pod_user) /ic/sbc/build/install/sbc/bin/sbc"
	sleep 15
}

#######################################
## tests tasks
#######################################

__run_integration_tests_container() {
	__binary_ic
	docker run --name integration --rm --network host -v "$PIPELINE_CLUSTER_PATH/ic-mount:/ic" \
		-w /ic "$CACHED_JDK_IMAGE" /bin/bash -c "$(__configure_pod_user) ./gradlew -i :integration-tests:integrationTests"
}

run_tests_pipeline() {
	__compile_binary_pipeline
	__run_sbc_container
	__run_integration_tests_container
}

help() {
	echo "Usage: ./main.sh <option>"
	echo "Available options:"
	compgen -A function | grep -v "__"
}

[ -z "$1" ] && help

"$@"
