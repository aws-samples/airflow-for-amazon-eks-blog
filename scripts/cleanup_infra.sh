kubectl delete ns airflow
helm delete cluster-autoscaler --namespace kube-system 
helm delete aws-efs-csi-driver --namespace kube-system 

aws efs delete-access-point --access-point-id $(aws efs describe-access-points --file-system-id $AOK_EFS_FS_ID --region $AOK_AWS_REGION --query 'AccessPoints[0].AccessPointId' --output text) --region $AOK_AWS_REGION
for mount_target in $(aws efs describe-mount-targets --file-system-id $AOK_EFS_FS_ID --region $AOK_AWS_REGION --query 'MountTargets[].MountTargetId' --output text); do aws efs delete-mount-target --mount-target-id $mount_target --region $AOK_AWS_REGION; done
sleep 15
aws efs delete-file-system --file-system-id $AOK_EFS_FS_ID --region $AOK_AWS_REGION
aws ec2 delete-security-group --group-id $AOK_EFS_SG_ID --region $AOK_AWS_REGION
aws rds delete-db-instance --db-instance-identifier airflow-postgres --delete-automated-backups --skip-final-snapshot --region $AOK_AWS_REGION
sleep 180
aws rds delete-db-subnet-group --db-subnet-group-name airflow-postgres-subnet --region $AOK_AWS_REGION
aws ecr delete-repository --repository-name airflow-eks-demo --force --region $AOK_AWS_REGION
eksctl delete cluster --name=$AOK_EKS_CLUSTER_NAME
