#!/bin/bash
export CONSUL_SERVER_IP=10.10.0.101

echo ECS_CLUSTER=chat-engine-cluster >> /etc/ecs/ecs.config

docker run -d --restart=always -h $(curl -s http://169.254.169.254/latest/meta-data/instance-id) \
-p 8300:8300 -p 8301:8301 -p 8301:8301/udp -p 8302:8302 -p 8302:8302/udp -p 8400:8400 -p 8500:8500 -p 172.17.0.1:53:53/udp \
gliderlabs/consul-agent -advertise $(curl -s http://169.254.169.254/latest/meta-data/local-ipv4) -join $CONSUL_SERVER_IP

docker run -d --restart=always --net=host -v /var/run/docker.sock:/tmp/docker.sock gliderlabs/registrator:latest -ip $(curl -s http://169.254.169.254/latest/meta-data/local-ipv4) consul://localhost:8500

docker run -d --restart=always -p 9999:9999 -p 9998:9998 -e SERVICE_9998_TAGS=urlprefix-/ rashidw3/fabio:latest
