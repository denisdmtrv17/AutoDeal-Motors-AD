# Network Topology
The topology consists of two Debian virtual machines: Gateway and Server.

The Gateway has three network interfaces:
- WAN – connected to the Internet through VirtualBox NAT.
- LAN1 – internal network with address: 10.80.0.1/24.
- LAN2 – second internal network.

The Server is connected to LAN1 and uses the static IP address: 10.80.0.50/24. Its default gateway is: 10.80.0.1.

IPv4 forwarding is enabled on the Gateway.
