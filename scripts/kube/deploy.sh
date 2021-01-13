#!/usr/bin/env bash
#
#  Licensed to the Apache Software Foundation (ASF) under one   *
#  or more contributor license agreements.  See the NOTICE file *
#  distributed with this work for additional information        *
#  regarding copyright ownership.  The ASF licenses this file   *
#  to you under the Apache License, Version 2.0 (the            *
#  "License"); you may not use this file except in compliance   *
#  with the License.  You may obtain a copy of the License at   *
#                                                               *
#    http://www.apache.org/licenses/LICENSE-2.0                 *
#                                                               *
#  Unless required by applicable law or agreed to in writing,   *
#  software distributed under the License is distributed on an  *
#  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY       *
#  KIND, either express or implied.  See the License for the    *
#  specific language governing permissions and limitations      *
#  under the License.                                           *

set -x

echo "Image" $IMAGE
echo "Image Tag" $TAG

AIRFLOW_IMAGE=$IMAGE
AIRFLOW_TAG=$TAG
DIRNAME=$(cd "$(dirname "$0")"; pwd)
TEMPLATE_DIRNAME=${DIRNAME}/templates
BUILD_DIRNAME=${DIRNAME}/build

if [ ! -d "$BUILD_DIRNAME" ]; then
  mkdir -p ${BUILD_DIRNAME}
fi

rm -f ${BUILD_DIRNAME}/*


INIT_DAGS_VOLUME_NAME=airflow-dags
POD_AIRFLOW_DAGS_VOLUME_NAME=airflow-dags
CONFIGMAP_DAGS_FOLDER=/root/airflow/dags
CONFIGMAP_GIT_DAGS_FOLDER_MOUNT_POINT=
CONFIGMAP_DAGS_VOLUME_CLAIM=airflow-dags

CONFIGMAP_GIT_REPO=${TRAVIS_REPO_SLUG:-apache/airflow}
CONFIGMAP_BRANCH=${TRAVIS_BRANCH:-master}

_UNAME_OUT=$(uname -s)
case "${_UNAME_OUT}" in
    Linux*)     _MY_OS=linux;;
    Darwin*)    _MY_OS=darwin;;
    *)          echo "${_UNAME_OUT} is unsupported."
                exit 1;;
esac
echo "Local OS is ${_MY_OS}"

case $_MY_OS in
  linux)
    SED_COMMAND=sed
  ;;
  darwin)
    SED_COMMAND=gsed
    if ! $(type "$SED_COMMAND" &> /dev/null) ; then
      echo "Could not find \"$SED_COMMAND\" binary, please install it. On OSX brew install gnu-sed" >&2
      exit 1
    fi
  ;;
  *)
    echo "${_UNAME_OUT} is unsupported."
    exit 1
  ;;
esac

${SED_COMMAND} -e "s/{{INIT_GIT_SYNC}}//g" \
    ${TEMPLATE_DIRNAME}/airflow.template.yaml > ${BUILD_DIRNAME}/airflow.yaml
${SED_COMMAND} -i "s|{{AIRFLOW_IMAGE}}|$AIRFLOW_IMAGE|g" ${BUILD_DIRNAME}/airflow.yaml
${SED_COMMAND} -i "s|{{AIRFLOW_TAG}}|$AIRFLOW_TAG|g" ${BUILD_DIRNAME}/airflow.yaml

${SED_COMMAND} -i "s|{{CONFIGMAP_GIT_REPO}}|$CONFIGMAP_GIT_REPO|g" ${BUILD_DIRNAME}/airflow.yaml
${SED_COMMAND} -i "s|{{CONFIGMAP_BRANCH}}|$CONFIGMAP_BRANCH|g" ${BUILD_DIRNAME}/airflow.yaml
${SED_COMMAND} -i "s|{{INIT_DAGS_VOLUME_NAME}}|$INIT_DAGS_VOLUME_NAME|g" ${BUILD_DIRNAME}/airflow.yaml
${SED_COMMAND} -i "s|{{POD_AIRFLOW_DAGS_VOLUME_NAME}}|$POD_AIRFLOW_DAGS_VOLUME_NAME|g" ${BUILD_DIRNAME}/airflow.yaml

${SED_COMMAND} "s|{{CONFIGMAP_DAGS_FOLDER}}|$CONFIGMAP_DAGS_FOLDER|g" \
    ${TEMPLATE_DIRNAME}/configmaps.template.yaml > ${BUILD_DIRNAME}/configmaps.yaml
${SED_COMMAND} -i "s|{{AIRFLOW_IMAGE}}|$AIRFLOW_IMAGE|g" ${BUILD_DIRNAME}/configmaps.yaml
${SED_COMMAND} -i "s|{{AIRFLOW_TAG}}|$AIRFLOW_TAG|g" ${BUILD_DIRNAME}/configmaps.yaml
${SED_COMMAND} -i "s|{{CONFIGMAP_GIT_REPO}}|$CONFIGMAP_GIT_REPO|g" ${BUILD_DIRNAME}/configmaps.yaml
${SED_COMMAND} -i "s|{{CONFIGMAP_BRANCH}}|$CONFIGMAP_BRANCH|g" ${BUILD_DIRNAME}/configmaps.yaml
${SED_COMMAND} -i "s|{{CONFIGMAP_GIT_DAGS_FOLDER_MOUNT_POINT}}|$CONFIGMAP_GIT_DAGS_FOLDER_MOUNT_POINT|g" ${BUILD_DIRNAME}/configmaps.yaml
${SED_COMMAND} -i "s|{{CONFIGMAP_DAGS_VOLUME_CLAIM}}|$CONFIGMAP_DAGS_VOLUME_CLAIM|g" ${BUILD_DIRNAME}/configmaps.yaml


cat ${BUILD_DIRNAME}/airflow.yaml
cat ${BUILD_DIRNAME}/configmaps.yaml

# Fix file permissions
if [[ "${TRAVIS}" == true ]]; then
  sudo chown -R travis.travis $HOME/.kube $HOME/.minikube
fi

kubectl delete -f $DIRNAME/postgres.yaml
kubectl delete -f $BUILD_DIRNAME/airflow.yaml
kubectl delete -f $DIRNAME/secrets.yaml
kubectl delete -f $DIRNAME/namespace.yaml

case $_MY_OS in
  linux)
    sleep 1m
  ;;
  darwin)
    sleep 60
  ;;
  *)
    echo "${_UNAME_OUT} is unsupported."
    exit 1
  ;;
esac
set -e

kubectl apply -f $DIRNAME/namespace.yaml
kubectl apply -f $DIRNAME/secrets.yaml
kubectl apply -f $BUILD_DIRNAME/configmaps.yaml
kubectl apply -f $DIRNAME/postgres.yaml
kubectl apply -f $DIRNAME/volumes.yaml
kubectl apply -f $BUILD_DIRNAME/airflow.yaml

# wait for up to 10 minutes for everything to be deployed
PODS_ARE_READY=0
for i in {1..150}
do
  echo "------- Running kubectl get pods -------"
  PODS=$(kubectl get pods -n airflow| awk 'NR>1 {print $0}')
  echo "$PODS"
  NUM_AIRFLOW_READY=$(echo $PODS | grep airflow | awk '{print $2}' | grep -E '([0-9])\/(\1)' | wc -l | xargs)
  NUM_POSTGRES_READY=$(echo $PODS | grep postgres | awk '{print $2}' | grep -E '([0-9])\/(\1)' | wc -l | xargs)
  if [ "$NUM_AIRFLOW_READY" == "1" ] && [ "$NUM_POSTGRES_READY" == "1" ]; then
    PODS_ARE_READY=1
    break
  fi
  sleep 4
done

if [[ "$PODS_ARE_READY" == 1 ]]; then
  echo "PODS are ready."
else
  echo "PODS are not ready after waiting for a long time. Exiting..."
  exit 1
fi
