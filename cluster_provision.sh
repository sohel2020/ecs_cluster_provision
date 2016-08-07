#!/bin/bash
#
#
# Purpose: ECS Cluster Init on AWS
# Maintainer: Tarikur Rahaman
# Email : tarikur@w3engineers.com
# Create Date: 03-06-2016
# Last Modified: 
#
#


# Create Cluster 
echo -n "Creating ECS cluster (Chat-Engine-Cluster) .. "
aws ecs create-cluster --cluster-name chat-engine-cluster > /dev/null
echo "done"

# Create VPC

echo -n "Creating VPC (chat-engine-vpc) .. "
VPC_ID=$(aws ec2 create-vpc --cidr-block 172.31.0.0/28 --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# Tag to trace resource in future
aws ec2 create-tags --resources $VPC_ID --tag Key=Name,Value=chat-engine
echo "done"

# Creare Subnet
echo -n "Creating Subnet (chat-engine-subnet) .. "
SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 172.31.0.0/28 --query 'Subnet.SubnetId' --output text)

# Tag to trace resource in future
aws ec2 create-tags --resources $SUBNET_ID --tag Key=Name,Value=chat-engine-subnet
echo "done"

# Create Internet Gateway
echo -n "Creating Internet Gateway (chat-engine-IG) .. "
GW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)

# Tag to trace resource in future
aws ec2 create-tags --resources $GW_ID --tag Key=Name,Value=weave-ecs-demo

# Attach IGW with our previously created VPC
aws ec2 attach-internet-gateway --internet-gateway-id $GW_ID --vpc-id $VPC_ID
TABLE_ID=$(aws ec2 describe-route-tables --query 'RouteTables[?VpcId==`'$VPC_ID'`].RouteTableId' --output text)

# Add Default Route to Internet gateway
aws ec2 create-route --route-table-id $TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $GW_ID > /dev/null
echo "done"

# Create Security group
echo -n "Creating Security Group (chat-engine) .. "
SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name chat-engine --vpc-id $VPC_ID --description 'chat-engine' --query 'GroupId' --output text)

# Wait for the group to get associated with the VPC
sleep 5
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 202.50.5.40/32
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 4040 --cidr 0.0.0.0/0

# Weave
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 6783 --source-group $SECURITY_GROUP_ID
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol udp --port 53 --source-group $SECURITY_GROUP_ID
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol udp --port 6784 --source-group $SECURITY_GROUP_ID


echo "done"

# Key pair
echo -n "Creating Key Pair (chat-engine.pem) .. "
aws ec2 create-key-pair --key-name weave-ecs-demo-key --query 'KeyMaterial' --output text > weave-ecs-demo-key.pem
chmod 600 chat-engine-key.pem
echo "done"

# IAM role
echo -n "Creating IAM role (weave-ecs-role) .. "
aws iam create-role --role-name weave-ecs-role --assume-role-policy-document file://data/weave-ecs-role.json > /dev/null
aws iam put-role-policy --role-name weave-ecs-role --policy-name weave-ecs-policy --policy-document file://data/weave-ecs-policy.json
aws iam create-instance-profile --instance-profile-name weave-ecs-instance-profile > /dev/null
# Wait for the instance profile to be ready, otherwise we get an error when trying to use it
while ! aws iam get-instance-profile --instance-profile-name weave-ecs-instance-profile  2>&1 > /dev/null; do
    sleep 2
done
aws iam add-role-to-instance-profile --instance-profile-name weave-ecs-instance-profile --role-name weave-ecs-role
echo "done"

# Launch configuration
echo -n "Creating Launch Configuration (weave-ecs-launch-configuration) .. "
# Wait for the role to be ready, otherwise we get:
# A client error (ValidationError) occurred when calling the CreateLaunchConfiguration operation: You are not authorized to perform this operation.
# Unfortunately even if you can list the profile, "aws autoscaling create-launch-configuration" barks about it not existing so lets sleep instead
# while [ "$(aws iam list-instance-profiles-for-role --role-name weave-ecs-role --query 'InstanceProfiles[?InstanceProfileName==`weave-ecs-instance-profile`].InstanceProfileName' --output text 2>/dev/null || true)" !=  weave-ecs-instance-profile ]; do
#    sleep 2
# done
sleep 15

TMP_USER_DATA_FILE=$(mktemp /tmp/weave-ecs-demo-user-data-XXXX)
trap 'rm $TMP_USER_DATA_FILE' EXIT
cp data/set-ecs-cluster-name.sh $TMP_USER_DATA_FILE
if [ -n "$SCOPE_AAS_PROBE_TOKEN" ]; then
    echo "echo SERVICE_TOKEN=$SCOPE_AAS_PROBE_TOKEN >> /etc/weave/scope.config" >> $TMP_USER_DATA_FILE
fi
aws autoscaling create-launch-configuration --image-id $AMI --launch-configuration-name weave-ecs-launch-configuration --key-name weave-ecs-demo-key --security-groups $SECURITY_GROUP_ID --instance-type t2.micro --user-data file://$TMP_USER_DATA_FILE  --iam-instance-profile weave-ecs-instance-profile --associate-public-ip-address --instance-monitoring Enabled=false
echo "done"

# Auto Scaling Group
echo -n "Creating Auto Scaling Group (weave-ecs-demo-group) with 3 instances .. "
aws autoscaling create-auto-scaling-group --auto-scaling-group-name weave-ecs-demo-group --launch-configuration-name weave-ecs-launch-configuration --min-size 3 --max-size 3 --desired-capacity 3 --vpc-zone-identifier $SUBNET_ID

# Useful to test peer-discovery using the weave:peerGroupName tag instead of Autoscaling-group-membership.
#aws autoscaling create-or-update-tags --tags "ResourceId=weave-ecs-demo-group,ResourceType=auto-scaling-group,Key=weave:peerGroupName,Value=test,PropagateAtLaunch=true"
echo "done"

# Wait for instances to join the cluster
echo -n "Waiting for instances to join the cluster (this may take a few minutes) .. "
while [ "$(aws ecs describe-clusters --clusters weave-ecs-demo-cluster --query 'clusters[0].registeredContainerInstancesCount' --output text)" != 3 ]; do
    sleep 2
done
echo "done"

# Task definition
echo -n "Registering ECS Task Definition (weave-ecs-demo-task) .. "
aws ecs register-task-definition --family weave-ecs-demo-task --container-definitions "$(cat data/weave-ecs-demo-containers.json)" > /dev/null
echo "done"

# Service
echo -n "Creating ECS Service with 3 tasks (weave-ecs-demo-service) .. "
aws ecs create-service --cluster weave-ecs-demo-cluster --service-name  weave-ecs-demo-service --task-definition weave-ecs-demo-task --desired-count 3 > /dev/null
echo "done"

# Wait for tasks to start running
echo -n "Waiting for tasks to start running .. "
while [ "$(aws ecs describe-clusters --clusters weave-ecs-demo-cluster --query 'clusters[0].runningTasksCount')" != 3 ]; do
    sleep 2
done
echo "done"


# Print out the public hostnames of the instances we created
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names weave-ecs-demo-group --query 'AutoScalingGroups[0].Instances[*].InstanceId' --output text)
DNS_NAMES=$(aws ec2 describe-instances --instance-ids $INSTANCE_IDS --query 'Reservations[0].Instances[*].PublicDnsName' --output text)

echo "Setup is ready!"
echo "Open your browser and go to any of these URLs:"
for NAME in $DNS_NAMES; do
    echo "  http://$NAME"
done