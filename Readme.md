# Airflow Kubernetes Setup

The setup files are copied directly from airflow's repo and modified to fit the requirements.


# Pre Req

1. An EKS Cluster.
2. Spot Managed Nodes on EKS Cluster with following setup: \
    a. Label ```lifecycle: Ec2Spot```. \
    b. Taints ```spotInstance: true:PreferNoSchedule```. \
    c. InstancesDistribution as ```spotAllocationStrategy: capacity-optimized```. \
    d. Note: Without Spot Nodes, Jobs will run in OnDemand Nodes. 
3. An ECR Repo to Push Airflow Docker Images.
# Steps 

1. Navigate to ```scripts\docker``` directory and build the Docker Image using ```docker build -t <ECR-uri:tag> .``` 
2. Push the image the ECR Repo using ```docker push <ECR-uri:tag>```
3. set the following environment variables on your terminal : \
    a. ```export AOK_AIRFLOW_REPOSITORY=<ECR-uri>```. \
4. Navigate to ```scrips\kube``` directory and run the ```./deploy.sh``` to deploy the kubernetes infrastructure for airflow.
5. Obtain the airflow URL by running ```kubectl get svc -n airflow```
6. Log in the airflow using the above URL with ```eksuser``` as user and ```ekspassword``` as password.
7. On your terminal, run ```kubectl get nodes --label-columns=lifecycle --selector=lifecycle=Ec2Spot``` to get a list of EC2.
8. On your terminal, run ```kubectl get pods -n airflow -w -o wide```.
9. Trigger one of the DAGs in Airflow console to see the pods triggered for the job in airflow console. 
10. On your terminal, verify the pods are getting triggered in the same spot nodes with label ```lifecycle: Ec2Spot``` as in step 7.