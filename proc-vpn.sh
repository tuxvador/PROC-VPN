#!/bin/bash

# This script sets up a network namespace for a VPN connection and routes a command's traffic through it.
# It ensures proper cleanup in case of script termination.

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Variables
INTF="wlan0"                             # Physical network interface to use
NAMESPACE="vpn"                          # Name of the network namespace
VETH_MAIN="veth0"                        # Main end of the virtual ethernet pair
VETH_NS="veth1"                          # Namespace end of the virtual ethernet pair
IP_MAIN="10.2.1.1/24"                    # IP address for the main end of the veth pair
IP_NS="10.2.1.2/24"                      # IP address for the namespace end of the veth pair
NETWORK="10.2.1.0/24"                    # Network address for the veth pair
VPN_CONFIG="/home/tuxvador/openvpn.ovpn" # Path to the VPN configuration file
COMMAND_TO_RUN="$@"                      # Command to run through the VPN passed as parameter to the script

# Cleanup function to be called on exit
cleanup() {
  echo "Cleaning up..."
  
  # Kill the VPN process running in the namespace
  pkill -f "ip netns exec $NAMESPACE openvpn"
  
  # Delete the network namespace
  ip netns delete $NAMESPACE
  
  # Remove the VETH pair
  ip link delete $VETH_MAIN
  
  # Remove iptables rules related to this setup
  iptables -D FORWARD -i ${INTF} -o ${VETH_MAIN} -j ACCEPT
  iptables -D FORWARD -o ${INTF} -i ${VETH_MAIN} -j ACCEPT
  iptables -t nat -D POSTROUTING -s ${NETWORK} -o ${INTF} -j MASQUERADE
  
  echo "Cleanup complete."
}

# Set trap to ensure cleanup is called on script exit or interruption
trap cleanup EXIT

# Create a new network namespace
ip netns add $NAMESPACE

# Create a virtual ethernet pair for communication between the namespace and the host
ip link add $VETH_MAIN type veth peer name $VETH_NS

# Assign one end of the veth pair to the namespace
ip link set $VETH_NS netns $NAMESPACE

# Configure the host side of the veth pair
ip addr add $IP_MAIN dev $VETH_MAIN
ip link set $VETH_MAIN up

# Configure the namespace side of the veth pair
ip netns exec $NAMESPACE ip addr add $IP_NS dev $VETH_NS
ip netns exec $NAMESPACE ip link set $VETH_NS up
ip netns exec $NAMESPACE ip link set lo up

# Set up routing within the namespace, making the host side of the veth pair the default gateway
ip netns exec $NAMESPACE ip route add default via ${IP_MAIN%/*}

# Flush existing FORWARD and NAT rules, set policy to DROP by default for security
iptables -P FORWARD DROP
iptables -F FORWARD
iptables -t nat -F

# Enable NAT (masquerading) for the namespace traffic
iptables -t nat -A POSTROUTING -s ${NETWORK} -o ${INTF} -j MASQUERADE

# Allow traffic forwarding between the physical interface and the veth pair
iptables -A FORWARD -i ${INTF} -o ${VETH_MAIN} -j ACCEPT
iptables -A FORWARD -o ${INTF} -i ${VETH_MAIN} -j ACCEPT

# Allow all outgoing traffic from the host
iptables -P OUTPUT ACCEPT

# Start the VPN client inside the namespace
ip netns exec $NAMESPACE openvpn --config $VPN_CONFIG &

# Wait for the VPN connection to establish
sleep 5

# Execute the specified command within the network namespace
ip netns exec $NAMESPACE $COMMAND_TO_RUN
