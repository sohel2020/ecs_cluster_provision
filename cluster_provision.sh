#!/bin/bash

#################################################
#												#
# Purpose: ECS Cluster Initialize on aws        #
# Maintainer: Tarikur Rahaman					#
# Email : tarikur@w3engineers.com 				#
# Create Date: 03-06-2016 						#
# Last Modified: 								#
#												#
#################################################

############# Global Variable Section ############

CLUSTER_NAME="chat-engine-cluster"
AMI_ID="ami-55870742" # Only for N.Virginia Region
INSTANCE_TYPE="t2.micro"
##################################################


# Check that we have everything 

if [ -z "$(which aws)" ]; then
    echo "error: Cannot find AWS-CLI, please make sure it's installed"
    exit 1
fi

REGION=$(aws configure list 2> /dev/null | grep region | awk '{ print $5 }')
if [ "$REGION" == "None"  ]; then
    echo "error: Region not set, please make sure to run 'aws configure'"
    exit 1
fi


# Create Cluster 
echo -n "Creating ECS cluster (Chat-Engine-Cluster) .. "
aws ecs create-cluster --cluster-name $CLUSTER_NAME > /dev/null
echo "done"

# Create VPC

echo -n "Creating VPC (chat-engine-vpc) .. "
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.10.0.0/24 --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# Tag to trace resource in future
aws ec2 create-tags --resources $VPC_ID --tag Key=Name,Value=chat-engine
echo "done"

# Creare Subnet
echo -n "Creating Subnet (chat-engine-subnet) .. "
SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.10.0.0/24 --query 'Subnet.SubnetId' --output text)

# Tag to trace resource in future
aws ec2 create-tags --resources $SUBNET_ID --tag Key=Name,Value=chat-engine-subnet
echo "done"

# Create Internet Gateway
echo -n "Creating Internet Gateway (chat-engine-IG) .. "
GW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)

# Tag to trace resource in future
aws ec2 create-tags --resources $GW_ID --tag Key=Name,Value=chat-engine-ecs

# Attach IGW with our previously created VPC
aws ec2 attach-internet-gateway --internet-gateway-id $GW_ID --vpc-id $VPC_ID
TABLE_ID=$(aws ec2 describe-route-tables --query 'RouteTables[?VpcId==`'$VPC_ID'`].RouteTableId' --output text)

# Add Default Route to Internet gateway
aws ec2 create-route --route-table-id $TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $GW_ID > /dev/null
echo "done"

# Create Security group
echo -n "Creating Security Group (chat-engine) .. "
SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name chat-engine --vpc-id $VPC_ID --description 'chat-engine' --query 'GroupId' --output text)

# Waiting for the group to get associated with the VPC
sleep 5
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 202.50.5.40/32
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 9999 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 0-65535 --cidr 10.10.0.0/24

echo "done"

# Key pair
echo -n "Creating Key Pair (chat-engine.pem) .. "
aws ec2 create-key-pair --key-name chat-engine-key --query 'KeyMaterial' --output text > chat-engine-key.pem
chmod 600 chat-engine-key.pem
echo "done"

# Creating IAM role
echo -n "Creating IAM role .. "
aws iam create-role --role-name chat-ecs-role --assume-role-policy-document file://data/chat-ecs-role.json > /dev/null
aws iam put-role-policy --role-name chat-ecs-role --policy-name chat-ecs-policy --policy-document file://data/ecs-ecr-policy.json
aws iam create-instance-profile --instance-profile-name chat-ecs-instance-profile > /dev/null

# Wait for the instance profile to be ready

while ! aws iam get-instance-profile --instance-profile-name chat-ecs-instance-profile  2>&1 > /dev/null; do
    sleep 2
done
aws iam add-role-to-instance-profile --instance-profile-name chat-ecs-instance-profile --role-name chat-ecs-role
echo "done"

# Launch configuration
echo -n "Creating Launch Configuration (chat-ecs-launch-configuration) .. "
echo "Waiting to Create Instances Profile"
sleep 15

TMP_USER_DATA_FILE=$(mktemp /tmp/ecs-user-data)
trap 'rm $TMP_USER_DATA_FILE' EXIT
cp data/user-data.sh $TMP_USER_DATA_FILE


# Create Elastic Load Balancer

echo -n "Creating Elastic Load Balancer .."
ELB_DNS=$(aws elb create-load-balancer --load-balancer-name chat-engine --listeners "Protocol=HTTP,LoadBalancerPort=80,InstanceProtocol=HTTP,InstancePort=9999" --subnets $SUBNET_ID --security-groups $SECURITY_GROUP_ID --output text)
echo "done"

aws autoscaling create-launch-configuration --image-id $AMI_ID --launch-configuration-name chat-ecs-launch-configuration --key-name chat-engine-key --security-groups $SECURITY_GROUP_ID --instance-type $INSTANCE_TYPE --user-data file://$TMP_USER_DATA_FILE  --iam-instance-profile chat-ecs-instance-profile --associate-public-ip-address --instance-monitoring Enabled=false
echo "done"

# Auto Scaling Group
echo -n "Creating Auto Scaling Group with 2 instances .. "
aws autoscaling create-auto-scaling-group --auto-scaling-group-name chat-ecs-ag --launch-configuration-name chat-ecs-launch-configuration --min-size 2 --max-size 6 --desired-capacity 2 --vpc-zone-identifier $SUBNET_ID

echo "done"

echo -n "Waiting for Attach Elastic Load Balancer with Autoscale Group .. "
aws autoscaling attach-load-balancers --load-balancer-names chat-engine --auto-scaling-group-name chat-ecs-ag

# Wait for instances to join the cluster
echo -n "Waiting for instances to join the cluster (this may take a few minutes) .. "
while [ "$(aws ecs describe-clusters --clusters $CLUSTER_NAME --query 'clusters[0].registeredContainerInstancesCount' --output text)" != 2 ]; do
    sleep 2
done
echo "done"



# Creating  Task definition
echo -n "Registering ECS Task Definition (chat-engine-task) .. "
aws ecs register-task-definition --family chat-engine-task --container-definitions "$(cat data/chat-engine-task.json)" > /dev/null
echo "done"

# Creating Service
echo -n "Creating ECS Service with 3 tasks (chat-engine-service) .. "
aws ecs create-service --cluster $CLUSTER_NAME --service-name  chat-engine-service --task-definition chat-engine-task --desired-count 3 > /dev/null
echo "done"

# Wait for tasks to start running
echo -n "Waiting for tasks to start running .. "
while [ "$(aws ecs describe-clusters --clusters $CLUSTER_NAME --query 'clusters[0].runningTasksCount')" != 3 ]; do
    sleep 2
done
echo "done"


echo "Setup is ready!"
echo "Open your browser and go to these URL:"
echo " http://$ELB_DNS"
