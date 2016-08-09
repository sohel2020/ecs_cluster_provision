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

REPO_NAME="chat-engine"
OUTPUT=`aws ecr create-repository --region us-east-1 --repository-name $REPO_NAME --output text | awk '{print $5}'`

echo "Your Repository name is: $OUTPUT"