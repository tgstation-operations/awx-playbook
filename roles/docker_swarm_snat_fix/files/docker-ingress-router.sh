#!/bin/bash

VERSION=3.1.0

# Ingress Routing Daemon v3.1.0
# Copyright © 2020-2021 Struan Bartlett
# ----------------------------------------------------------------------
# Permission is hereby granted, free of charge, to any person 
# obtaining a copy of this software and associated documentation files 
# (the "Software"), to deal in the Software without restriction, 
# including without limitation the rights to use, copy, modify, merge, 
# publish, distribute, sublicense, and/or sell copies of the Software, 
# and to permit persons to whom the Software is furnished to do so, 
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be 
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, 
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND 
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
# BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN 
# ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN 
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE 
# SOFTWARE.
# ----------------------------------------------------------------------
# Workaround for https://github.com/moby/moby/issues/25526

log() {
  [ -z "$_BASHPID" ] && _BASHPID="$BASHPID"
  local D=$(date +%Y-%m-%d.%H:%M:%S.%N)
  local S=$(printf "%s|%s|%05d|" "${D:0:26}" "$HOSTNAME" "$_BASHPID")
  echo "$@" | sed "s/^/$S /g"
}			

quit() {
  trap '' EXIT TERM INT
  log "Docker Ingress Routing Daemon received signal, propagating it to pgroup $$ ..."
  kill -TERM -$$
  log "Docker Ingress Routing Daemon exiting."
  exit 0
}

detect_ingress() {
  read INGRESS_SUBNET INGRESS_DEFAULT_GATEWAY \
    < <(docker inspect ingress --format '{{(index .IPAM.Config 0).Subnet}} {{index (split (index .Containers "ingress-sbox").IPv4Address "/") 0}}')
    
  [ -n"$INGRESS_SUBNET" ] && [ -n"$INGRESS_DEFAULT_GATEWAY" ] && return 0
  
  return 1
}

usage() {
  echo "Usage: $0 [--install [OPTIONS] | --uninstall | --help]" >&2
  echo >&2
  echo "           --services <services>  - service names to disable masquerading for" >&2
  echo "           --tcp-ports <ports>    - TCP ports to disable masquerading for" >&2
  echo "           --udp-ports <ports>    - UDP ports to disable masquerading for" >&2
  echo "   --ingress-gateway-ips <ips>    - specify load-balance ingress IPs" >&2
  echo "              --no-performance    - disable performance optimisations" >&2
  echo >&2
  echo "    (services, ports and IPs may be comma or space-separated or may be specified" >&2
  echo "     multiple times)" >&2
  echo >&2
  
  if detect_ingress; then
    echo "!!! Ingress subnet: $INGRESS_SUBNET" >&2
    echo "!!! This node's ingress network IP: $INGRESS_DEFAULT_GATEWAY" >&2
  fi
  
  echo >&2
  exit 1
}

SCRIPT_PATH=$(dirname $(realpath $0))
DOCKER=$(which docker)

while true
do
  case "$1" in
        --services) shift; SERVICES+=($(echo "$1" | tr ',' ' ')); shift; continue; ;;
       --tcp-ports) shift; TCP_PORTS+=($(echo "$1" | tr ',' ' ')); shift; continue; ;;
       --udp-ports) shift; UDP_PORTS+=($(echo "$1" | tr ',' ' ')); shift; continue; ;;
         --install) shift; INSTALL=1; continue; ;;
       --uninstall) shift; INSTALL=0; continue; ;;
     --ingress-gateway-ips) shift; INGRESS_NODE_GATEWAY_IPS+=($(echo "$1" | tr ',' ' ')); shift; continue; ;;
  --no-performance) shift; PERFORMANCE=0; continue; ;;
   
      -h|--help) usage; ;;
             '') break; ;;
	     
              *) usage; break; ;;
  esac
done

# Display usage, unless --install or --uninstall
[ -z "$INSTALL" ] && usage

# Convert arrays to comma-separated strings
TCPServicePortString=$(echo ${TCP_PORTS[@]} | tr ' ' ',')
UDPServicePortString=$(echo ${UDP_PORTS[@]} | tr ' ' ',')

if [ ${#INGRESS_NODE_GATEWAY_IPS[@]} -gt 0 ]; then
  INGRESS_NODE_GATEWAY_IPS=$(echo ${INGRESS_NODE_GATEWAY_IPS[@]})
fi

# Prevent "WARNING: Error loading config file: .dockercfg: $HOME is not defined" messages
export HOME=$SCRIPT_PATH

if ! [ -x "$DOCKER" ]; then
  echo "Docker binary not found; exiting." >&2
  exit -1
fi

log "Docker Ingress Routing Daemon $VERSION starting ..."

if detect_ingress; then
  log "Detected ingress subnet: $INGRESS_SUBNET" >&2
  log "This node's ingress network IP: $INGRESS_DEFAULT_GATEWAY" >&2
else
  log "Couldn't identify ingress network subnet or this node's ingress network IP; sleeping 1s, then exiting."
  sleep 1
  exit -1
fi

# Delete any relevant preexisting rules.
nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t nat -S | \
  grep -- '-m ipvs --ipvs -j ACCEPT' | \
  sed -r 's/^-A /-D /' | \
  while read RULE; \
  do
    log "Deleting old rule: iptables -t nat $RULE"
    nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t nat $RULE
  done

nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t mangle -S | \
  grep -- '-j TOS --set-tos' | \
  sed -r 's/^-A /-D /' | \
  while read RULE; \
  do
    log "Deleting old rule: iptables -t mangle $RULE"
    nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t mangle $RULE
  done

nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t raw -S | \
  grep -- '-j CT --notrack' | \
  sed -r 's/^-A /-D /' | \
  while read RULE; \
  do
    log "Deleting old rule: iptables -t raw $RULE"
    nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t raw $RULE
  done

if [ "$INSTALL" = "0" ]; then
  log "Docker Ingress Routing Daemon iptables rules uninstalled, exiting."
  exit 0
fi

###############
# $INSTALL is 1
#

if [ -z "$INGRESS_NODE_GATEWAY_IPS" ]; then
  INGRESS_NET=$(echo $INGRESS_DEFAULT_GATEWAY | cut -d'.' -f1,2,3)
  INGRESS_NODE_GATEWAY_IPS="$INGRESS_NET.2 $INGRESS_NET.3 $INGRESS_NET.4 $INGRESS_NET.5 $INGRESS_NET.6 $INGRESS_NET.7 $INGRESS_NET.8 $INGRESS_NET.9 $INGRESS_NET.10 $INGRESS_NET.11 $INGRESS_NET.12 $INGRESS_NET.13 $INGRESS_NET.14 $INGRESS_NET.15 $INGRESS_NET.16 $INGRESS_NET.17 $INGRESS_NET.18 $INGRESS_NET.19 $INGRESS_NET.20 $INGRESS_NET.21 $INGRESS_NET.22 $INGRESS_NET.23 $INGRESS_NET.24 $INGRESS_NET.25 $INGRESS_NET.26 $INGRESS_NET.27 $INGRESS_NET.28 $INGRESS_NET.29 $INGRESS_NET.30 $INGRESS_NET.31 $INGRESS_NET.32"
  
  log "!!! -------------------------- WARNING ------------------------------------"
  log "!!! Assuming --ingress-gateway-ips $INGRESS_NODE_GATEWAY_IPS"
  log "!!!"
  log "!!! Please compile a list of the ingress network IPs of each of your nodes"
  log "!!! that you will be using as a load-balancer."
  log "!!!"
  log "!!! You only have to do this once, or whenever you change your set of"
  log "!!! load-balancer nodes."
  log "!!!"
  log "!!! Then relaunch using:"
  log "!!! $0 --install --ingress-gateway-ips \"<Node Ingress IP List>\""
  log "!!! ----------------------------------------------------------------------"

fi

log "Running with --ingress-gateway-ips $INGRESS_NODE_GATEWAY_IPS"

# Create node ID from INGRESS_DEFAULT_GATEWAY final byte
NODE_ID=$(echo $INGRESS_DEFAULT_GATEWAY | cut -d'.' -f4)
log "This node's ID is: $NODE_ID"

# Add a rule ahead of the ingress network SNAT rule, that will cause the SNAT rule to be skipped.
if [ -z "$TCPServicePortString" ] && [ -z "$UDPServicePortString" ]; then
  log "Adding ingress_sbox iptables nat rule: iptables -t nat -I POSTROUTING -d $INGRESS_SUBNET -m ipvs --ipvs -j ACCEPT"
  nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t nat -I POSTROUTING -d $INGRESS_SUBNET -m ipvs --ipvs -j ACCEPT

  # 1. Set TOS to NODE_ID in all outgoing packets to INGRESS_SUBNET
  log "Adding ingress_sbox iptables mangle rule: iptables -t mangle -A POSTROUTING -d $INGRESS_SUBNET -j TOS --set-tos $NODE_ID/0xff"
  nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t mangle -A POSTROUTING -d $INGRESS_SUBNET -j TOS --set-tos $NODE_ID/0xff

  log "Adding ingress_sbox connection tracking disable rule: iptables -t raw -I PREROUTING -j CT --notrack"
  nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t raw -I PREROUTING -j CT --notrack
else

  if [ -n "$TCPServicePortString" ]; then
    log "Adding ingress_sbox iptables nat rule: iptables -t nat -I POSTROUTING -d $INGRESS_SUBNET -p tcp -m multiport --dports $TCPServicePortString -m ipvs --ipvs -j ACCEPT"
    nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t nat -I POSTROUTING -d $INGRESS_SUBNET -p tcp -m multiport --dports $TCPServicePortString -m ipvs --ipvs -j ACCEPT

    # 1. Set TOS to NODE_ID in all outgoing packets to INGRESS_SUBNET
    log "Adding ingress_sbox iptables mangle rule: iptables -t mangle -A POSTROUTING -d $INGRESS_SUBNET -p tcp -m multiport --dports $TCPServicePortString -j TOS --set-tos $NODE_ID/0xff"
    nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t mangle -A POSTROUTING -d $INGRESS_SUBNET -p tcp -m multiport --dports $TCPServicePortString -j TOS --set-tos $NODE_ID/0xff

    log "Adding ingress_sbox connection tracking disable rule: iptables -t raw -I PREROUTING -p tcp -m multiport --dports $TCPServicePortString -j CT --notrack"
    nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t raw -I PREROUTING -p tcp -m multiport --dports $TCPServicePortString -j CT --notrack
  fi

  if [ -n "$UDPServicePortString" ]; then
    log "Adding ingress_sbox iptables nat rule: iptables -t nat -I POSTROUTING -d $INGRESS_SUBNET -p udp -m multiport --dports $UDPServicePortString -m ipvs --ipvs -j ACCEPT"
    nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t nat -I POSTROUTING -d $INGRESS_SUBNET -p udp -m multiport --dports $UDPServicePortString -m ipvs --ipvs -j ACCEPT

    # 1. Set TOS to NODE_ID in all outgoing packets to INGRESS_SUBNET
    log "Adding ingress_sbox iptables mangle rule: iptables -t mangle -A POSTROUTING -d $INGRESS_SUBNET -p udp -m multiport --dports $UDPServicePortString -j TOS --set-tos $NODE_ID/0xff"
    nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t mangle -A POSTROUTING -d $INGRESS_SUBNET -p udp -m multiport --dports $UDPServicePortString -j TOS --set-tos $NODE_ID/0xff

    log "Adding ingress_sbox connection tracking disable rule: iptables -p udp -m multiport --dports $UDPServicePortString -j CT --notrack"
    nsenter --net=/var/run/docker/netns/ingress_sbox iptables -t raw -I PREROUTING -p udp -m multiport --dports $UDPServicePortString -j CT --notrack
  fi

fi

if [ "$PERFORMANCE" != "0" ]; then
  # Set sysctl variables
  log "Setting ingress_sbox namespace sysctl variables net.ipv4.vs.conn_reuse_mode=0 net.ipv4.vs.expire_nodest_conn=1 net.ipv4.vs.expire_quiescent_template=1"
  nsenter --net=/var/run/docker/netns/ingress_sbox sysctl net.ipv4.vs.conn_reuse_mode=0 net.ipv4.vs.expire_nodest_conn=1 net.ipv4.vs.expire_quiescent_template=1
  
  log "Setting ingress_sbox namespace sysctl conntrack variables from /etc/sysctl.d/conntrack.conf"
  [ -f "/etc/sysctl.d/conntrack.conf" ] && nsenter --net=/var/run/docker/netns/ingress_sbox sysctl --load=/etc/sysctl.d/conntrack.conf
  
  log "Setting ingress_sbox namespace sysctl ipvs variables from /etc/sysctl.d/ipvs.conf"
  [ -f "/etc/sysctl.d/ipvs.conf" ] && nsenter --net=/var/run/docker/netns/ingress_sbox sysctl --load=/etc/sysctl.d/ipvs.conf
fi

log "Docker Ingress Routing Daemon launching docker event watcher in pgroup $$ ..."

# Turn off job control
set +m

# Set lastpipe, so that the 'while read' runs in the main shell process,
# making the script more resilient to subprocess exit.
shopt -s lastpipe

trap quit EXIT TERM INT

# Watch for container start events, and configure policy routing rules on each container
# to ensure return path traffic for incoming connections is routed back via the correct interface
# and to the correct node from which the incoming connection was received.
docker events \
  --format '{{.ID}} {{index .Actor.Attributes "com.docker.swarm.service.name"}}' \
  --filter 'event=start' \
  --filter 'type=container' | \
  while read ID SERVICE
  do
    if [ -z "$SERVICE" ]; then
      continue
    fi

    if [ ${#SERVICES[@]} -gt 0 ] && ! [[ " ${SERVICES[@]} " =~ " $SERVICE " ]]; then
      log "Container SERVICE=$SERVICE, ID=$ID launched: unmatched service, so skipping."
      continue
    fi

    NID=$(docker inspect -f '{{.State.Pid}}' $ID)
    CIF=$(nsenter -n -t $NID ip -brief addr show to $INGRESS_SUBNET | cut -d'@' -f1)

    if [ -z "$CIF" ]; then
      log "Container SERVICE=$SERVICE, ID=$ID, NID=$NID launched: no ingress network interface found, so skipping applying policy routes."
      continue
    fi

    log "Container SERVICE=$SERVICE, ID=$ID, NID=$NID launched: ingress network interface $CIF found, so applying policy routes."
     
    # 3. Map any connection mark on outgoing traffic to a firewall mark on the individual packets.
    nsenter -n -t $NID iptables -t mangle -A OUTPUT -p tcp -j CONNMARK --restore-mark

    # 3.1 Enable 'loose' rp_filter mode on interface $CIF (and 'all' as required by kernel
    #     see https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt)
    nsenter -n -t $NID sysctl net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.$CIF.rp_filter=2

    for NODE_IP in $INGRESS_NODE_GATEWAY_IPS
    do
      NODE_ID=$(echo $NODE_IP | cut -d'.' -f4)
	
      # 2. Map the TOS value on any incoming packets to a connection mark, using the same value.
      nsenter -n -t $NID iptables -t mangle -A PREROUTING -m tos --tos $NODE_ID/0xff -j CONNMARK --set-xmark $NODE_ID/0xffffffff
	
      # 4. Select the correct routing table to use, according to the firewall mark on the outgoing packet.
      nsenter -n -t $NID ip rule add from $INGRESS_SUBNET fwmark $NODE_ID lookup $NODE_ID prio 32700
	
      # 5. Route outgoing traffic to the correct node's ingress network IP, according to its firewall mark
      #    (which in turn came from its connection mark, its TOS value, and ultimately its IP).
      nsenter -n -t $NID ip route add table $NODE_ID default via $NODE_IP
	
    done
  done
