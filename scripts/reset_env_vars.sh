#!/usr/bin/env bash
# This script will perform the following:
# 1. Resets all the environment variables for deploying airflow on an existing EKS custer
# This script should be run using the command ". ./reset_env_vars.sh" to preserve the environment variables.

export AOK_AWS_REGION=us-west-2 #<-- Change this to match your region
export AOK_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
export AOK_EKS_CLUSTER_NAME=Airflow-on-Kubernetes 

printf "Setting EFS file system...\n"
export AOK_EFS_FS_ID=$(aws efs describe-file-systems \
  --creation-token Airflow-on-EKS \
  --region $AOK_AWS_REGION \
  --output text \
  --query "FileSystems[0].FileSystemId")

printf "Setting EFS access point...\n"
export AOK_EFS_AP=$(aws efs describe-access-points \
  --file-system-id $AOK_EFS_FS_ID \
  --region $AOK_AWS_REGION \
  --query 'AccessPoints[0].AccessPointId' \
  --output text)
 
printf "Setting RDS security group...\n"
export AOK_RDS_SG=$(aws rds describe-db-instances \
   --db-instance-identifier airflow-postgres \
   --region $AOK_AWS_REGION \
   --query "DBInstances[].VpcSecurityGroups[].VpcSecurityGroupId" \
   --output text)

printf "Setting RDS endpoint....\n"
export AOK_RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier airflow-postgres \
  --query 'DBInstances[0].Endpoint.Address' \
  --region $AOK_AWS_REGION \
  --output text)

printf "Setting an SQL connection string....\n"

_UNAME_OUT=$(uname -s)
case "${_UNAME_OUT}" in
    Linux*)     _MY_OS=linux;;
    Darwin*)    _MY_OS=darwin;;
    *)          echo "${_UNAME_OUT} is unsupported."
                exit 1;;s
esac
echo "Local OS is ${_MY_OS}"

case $_MY_OS in
  linux)
    export AOK_SQL_ALCHEMY_CONN=$(echo -n postgresql://airflowadmin:supersecretpassword@${AOK_RDS_ENDPOINT}:5432/airflow | base64 -w 0)
  ;;
  darwin)
    export AOK_SQL_ALCHEMY_CONN=$(echo -n postgresql://airflowadmin:supersecretpassword@${AOK_RDS_ENDPOINT}:5432/airflow | base64)
  ;;
  *)
    echo "${_UNAME_OUT} is unsupported."
    exit 1
  ;;
esac

export AOK_AIRFLOW_REPOSITORY=$(aws ecr describe-repositories \
  --repository-name airflow-eks-demo \
  --region $AOK_AWS_REGION \
  --query 'repositories[0].repositoryUri' \
  --output text)