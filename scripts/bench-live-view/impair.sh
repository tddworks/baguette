#!/bin/zsh
# usage: sudo ./impair.sh <delay_ms> <loss 0..1> [bw e.g. 5Mbit/s]   |   sudo ./impair.sh off
#        sudo IMPAIR_SCOPE=loopback-udp ./impair.sh …   every loopback UDP datagram, both ways (any sender's ports)
# Impairs only server→browser video: WS frames (from tcp 8421) and WebRTC media from every sender start.sh runs
# (udp 8189 MediaMTX, 8190-8194 baguette serve --webrtc-ports, 8195-8199 Pion), on every interface — loopback for
# a browser on this Mac, Tailscale or Wi-Fi for a phone. A phone's WebSocket comes through the proxy (8777), so on
# a phone only WebRTC is impaired. Taps and the browser's feedback are untouched. Check it took: `sudo pfctl -a bench -vsr` counts the packets each rule matched.
if [[ $1 == off ]]; then pfctl -f /etc/pf.conf 2>/dev/null; dnctl -q flush; echo off; exit; fi
dnctl pipe 1 config delay $1 plr $2 ${3:+bw $3}
dnctl pipe 2 config delay $1 plr $2 ${3:+bw $3}
sed -e '/^dummynet-anchor "com.apple/a\
dummynet-anchor "bench"' /etc/pf.conf | pfctl -q -f -
if [[ $IMPAIR_SCOPE == loopback-udp ]]; then
  # Every UDP datagram on loopback, both ways: for a sender whose ports aren't known in advance (one that picks
  # them at random), so all senders on this Mac compare under the same loss. Media, feedback and checks alike.
  print "dummynet out quick on lo0 proto udp from any to any pipe 2" | pfctl -q -a bench -f -
else
  printf '%s\n' "dummynet out quick proto tcp from any port 8421 to any pipe 1" \
                "dummynet out quick proto udp from any port 8189:8199 to any pipe 2" | pfctl -q -a bench -f -
fi
pfctl -q -E 2>/dev/null; dnctl show | head -4
