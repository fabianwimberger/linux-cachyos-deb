#!/bin/sh
# Profiling target only, run as root: sudo profile-wg.sh up|down. See
# docs/PROFILING.md.
#
# WireGuard tunnel from the root namespace (wg0, 10.99.0.1) into a private
# namespace (wg1, 10.99.0.2) over a veth pair. Two tunnel ends in one
# namespace would be routed over lo and never encrypt anything.
set -e
# Ubuntu's AppArmor profile for wg only lets it read keys under /etc/wireguard.
d=/etc/wireguard/prf-wg
case "$1" in
up)
    if [ ! -f "$d/wg0.key" ]; then
        mkdir -p "$d"
        (umask 077; wg genkey > "$d/wg0.key"; wg genkey > "$d/wg1.key")
    fi
    ip netns add prf-wg
    ip link add prf-veth0 type veth peer name prf-veth1 netns prf-wg
    ip addr add 10.98.0.1/30 dev prf-veth0
    ip link set prf-veth0 up
    ip -n prf-wg link set lo up
    ip -n prf-wg addr add 10.98.0.2/30 dev prf-veth1
    ip -n prf-wg link set prf-veth1 up
    ip link add wg0 type wireguard
    wg set wg0 listen-port 51820 private-key "$d/wg0.key" \
        peer "$(wg pubkey < "$d/wg1.key")" allowed-ips 10.99.0.2/32 endpoint 10.98.0.2:51821
    ip addr add 10.99.0.1/24 dev wg0
    ip link set wg0 up
    # Created inside the namespace, so its UDP socket lives there too.
    ip -n prf-wg link add wg1 type wireguard
    ip netns exec prf-wg wg set wg1 listen-port 51821 private-key "$d/wg1.key" \
        peer "$(wg pubkey < "$d/wg0.key")" allowed-ips 10.99.0.1/32 endpoint 10.98.0.1:51820
    ip -n prf-wg addr add 10.99.0.2/24 dev wg1
    ip -n prf-wg link set wg1 up
    ;;
down)
    ip link del wg0 2>/dev/null || true
    ip netns del prf-wg 2>/dev/null || true
    ;;
*)
    echo "usage: profile-wg.sh up|down" >&2
    exit 1
    ;;
esac
