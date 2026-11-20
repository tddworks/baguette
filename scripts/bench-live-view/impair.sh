#!/bin/zsh
# usage: sudo ./impair.sh <delay_ms> <loss 0..1> [bw e.g. 5Mbit/s]   |   sudo ./impair.sh off
# Impairs only server→browser video: WS frames (from tcp 8421) and WebRTC media (from udp 8189). Taps are untouched.
if [[ $1 == off ]]; then pfctl -f /etc/pf.conf 2>/dev/null; dnctl -q flush; echo off; exit; fi
dnctl pipe 1 config delay $1 plr $2 ${3:+bw $3}
dnctl pipe 2 config delay $1 plr $2 ${3:+bw $3}
sed -e '/^dummynet-anchor "com.apple/a\
dummynet-anchor "bench"' /etc/pf.conf | pfctl -q -f -
printf '%s\n' "dummynet out quick on lo0 proto tcp from any port 8421 to any pipe 1" \
              "dummynet out quick on lo0 proto udp from any port 8189 to any pipe 2" | pfctl -q -a bench -f -
pfctl -q -E 2>/dev/null; dnctl show | head -4
