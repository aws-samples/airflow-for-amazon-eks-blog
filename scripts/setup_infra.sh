#!/usr/bin/env bash
# This script will perform the following:
# 1. Deploy Kubernetes Cluster Autoscaler.
# 2. Deploy the EFS CSI driver and create EFS filesystem and Access Point.
# 3. Deploy an Amazon RDS PostgreSQL database.
# 4. Creates an ECR Repository for holding Airflow Docker Image.
# This script should be run using the command ". ./setup_infra.sh" to preserve the environment variables.

# Prerequisites:
# - AWS Profile should be setup on the executing shell.
# - Environment variables AOK_AWS_REGION, AOK_EKS_CLUSTER_NAME should be set.


printf "Step1. Deploy Kubernetes Cluster Autoscaler.\n"

printf "Associating OIDC provider with the EKS cluster....\n"

eksctl utils associate-iam-oidc-provider \
   --region $AOK_AWS_REGION \
   --cluster $AOK_EKS_CLUSTER_NAME\
   --approve
   
printf "Creating an IAM policy document for cluster autoscaler....\n"
cat << EOF > cluster-autoscaler-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeLaunchConfigurations",
                "autoscaling:DescribeTags",
                "autoscaling:SetDesiredCapacity",
                "autoscaling:TerminateInstanceInAutoScalingGroup",
                "ec2:DescribeLaunchTemplateVersions"
            ],
            "Resource": "*",
            "Effect": "Allow"
        }
    ]
}
EOF

printf "Creating the IAM policy....\n"
aws iam create-policy \
  --policy-name AmazonEKSClusterAutoscalerPolicy \
  --policy-document file://cluster-autoscaler-policy.json

printf "Creating  service account for cluster autoscaler....\n"
eksctl create iamserviceaccount \
  --cluster=$AOK_EKS_CLUSTER_NAME \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --attach-policy-arn=arn:aws:iam::$AOK_ACCOUNT_ID:policy/AmazonEKSClusterAutoscalerPolicy \
  --override-existing-serviceaccounts \
  --region $AOK_AWS_REGION \
  --approve

printf "Adding the cluster autoscaler helm repo....\n"
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

printf "Installing the cluster autoscaler....\n"
helm install cluster-autoscaler \
  autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set 'autoDiscovery.clusterName'=$AOK_EKS_CLUSTER_NAME \
  --set awsRegion=$AOK_AWS_REGION \
  --set cloud-provider=aws \
  --set extraArgs.balance-similar-node-groups=true \
  --set extraArgs.skip-nodes-with-system-pods=true \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler



printf "2. Deploy the EFS CSI driver and create EFS filesystem and Access Point.\n"

printf "Deploying EFS Driver....\n"
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update
helm upgrade --install aws-efs-csi-driver \
  aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system

printf "Getting the VPC of the EKS cluster and its CIDR block....\n"
export AOK_VPC_ID=$(aws eks describe-cluster --name $AOK_EKS_CLUSTER_NAME \
  --region $AOK_AWS_REGION \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)
export AOK_CIDR_BLOCK=$(aws ec2 describe-vpcs --vpc-ids $AOK_VPC_ID \
  --query "Vpcs[].CidrBlock" \
  --region $AOK_AWS_REGION \
  --output text)

printf "Creating a security group for EFS, and allow inbound NFS traffic (port 2049):....\n"
export AOK_EFS_SG_ID=$(aws ec2 create-security-group \
  --region $AOK_AWS_REGION \
  --description Airflow-on-EKS \
  --group-name Airflow-on-EKS \
  --vpc-id $AOK_VPC_ID \
  --query 'GroupId' \
  --output text)
  
aws ec2 authorize-security-group-ingress \
  --group-id $AOK_EFS_SG_ID \
  --protocol tcp \
  --port 2049 \
  --cidr $AOK_CIDR_BLOCK \
  --region $AOK_AWS_REGION

printf "Creating an EFS file system....\n"
export AOK_EFS_FS_ID=$(aws efs create-file-system \
  --creation-token Airflow-on-EKS \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --region $AOK_AWS_REGION \
  --tags Key=Name,Value=AirflowVolume \
  --encrypted \
  --output text \
  --query "FileSystemId")

printf "Waiting for 10 seconds....\n"
sleep 10

printf "Creating EFS mount targets in each subnet attached to on-demand nodes....\n"
for subnet in $(aws eks describe-nodegroup \
  --cluster-name $AOK_EKS_CLUSTER_NAME \
  --nodegroup-name ng-on-demand \
  --region $AOK_AWS_REGION \
  --output text \
  --query "nodegroup.subnets"); \
do (aws efs create-mount-target \
  --file-system-id $AOK_EFS_FS_ID \
  --subnet-id $subnet \
  --security-group $AOK_EFS_SG_ID \
  --region $AOK_AWS_REGION); \
done

printf "Creating an EFS access point....\n"
export AOK_EFS_AP=$(aws efs create-access-point \
  --file-system-id $AOK_EFS_FS_ID \
  --posix-user Uid=1000,Gid=1000 \
  --root-directory "Path=/airflow,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=777}" \
  --region $AOK_AWS_REGION \
  --query 'AccessPointId' \
  --output text)

printf "3. Deploy an Amazon RDS PostgreSQL database.\n"

printf "Obtaining the list of Private Subnets in Env variables....\n"
AOK_PRIVATE_SUBNETS=$(aws eks describe-nodegroup \
  --cluster-name $AOK_EKS_CLUSTER_NAME \
  --nodegroup-name ng-on-demand \
  --region $AOK_AWS_REGION \
  --output text \
  --query "nodegroup.subnets" | awk -v OFS="," '{for(i=1;i<=NF;i++)if($i~/subnet/)$i="\"" $i "\"";$1=$1}1')

printf "Creating a DB Subnet group....\n"
aws rds create-db-subnet-group \
   --db-subnet-group-name airflow-postgres-subnet \
   --subnet-ids "[$AOK_PRIVATE_SUBNETS]" \
   --db-subnet-group-description "Subnet group for Postgres RDS" \
   --region $AOK_AWS_REGION

printf "Creating the RDS Postgres Instance....\n"
aws rds create-db-instance \
  --db-instance-identifier airflow-postgres \
  --db-instance-class db.t3.micro \
  --db-name airflow \
  --db-subnet-group-name airflow-postgres-subnet \
  --engine postgres \
  --master-username airflowadmin \
  --master-user-password supersecretpassword \
  --allocated-storage 20 \
  --no-publicly-accessible \
  --region $AOK_AWS_REGION
  
  
printf "Creating RDS security group....\n"
AOK_RDS_SG=$(aws rds describe-db-instances \
   --db-instance-identifier airflow-postgres \
   --region $AOK_AWS_REGION \
   --query "DBInstances[].VpcSecurityGroups[].VpcSecurityGroupId" \
   --output text)

printf "Authorizing traffic....\n"
aws ec2 authorize-security-group-ingress \
  --group-id $AOK_RDS_SG \
  --cidr $AOK_CIDR_BLOCK \
  --port 5432 \
  --protocol tcp \
  --region $AOK_AWS_REGION

printf "Waiting for 5 minutes....\n"
sleep 300 

printf "Checking if the RDS Instance is up ....\n"
aws rds describe-db-instances \
  --db-instance-identifier airflow-postgres \
  --region $AOK_AWS_REGION \
  --query "DBInstances[].DBInstanceStatus"

printf "Creating an RDS endpoint....\n"
export AOK_RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier airflow-postgres \
  --query 'DBInstances[0].Endpoint.Address' \
  --region $AOK_AWS_REGION \
  --output text)

printf "Creating an SQL connection string....\n"
export AOK_SQL_ALCHEMY_CONN=$(echo -n postgresql://airflowadmin:supersecretpassword@${AOK_RDS_ENDPOINT}:5432/airflow | base64)

export AOK_AIRFLOW_REPOSITORY=$(aws ecr create-repository \
  --repository-name airflow-eks-demo \
  --region $AOK_AWS_REGION \
  --query 'repository.repositoryUri' \
  --output text)