import Foundation

/// The offer Chrome 157 (macOS) posts to a WHEP viewer, captured 2026-11-22 from
/// a recvonly transceiver set up as `whep-session.js` does (H.264 first, every
/// other codec after): ten H.264 formats — High profile at 118 — and H.265 at 49
/// (Main, `profile-id=1`) and 51 (Main 10), each with its RTX format.
let chrome157Offer = #"""
v=0
o=- 5798198689096795904 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
a=extmap-allow-mixed
a=msid-semantic: WMS
m=video 9 UDP/TLS/RTP/SAVPF 102 103 104 107 108 109 114 115 116 117 39 40 41 42 43 44 118 119 120 121 96 97 98 99 100 101 35 36 37 38 45 46 47 48 49 50 51 52 122 123 124 53
c=IN IP4 0.0.0.0
a=rtcp:9 IN IP4 0.0.0.0
a=ice-ufrag:ri2M
a=ice-pwd:p+lTt2vkIneoSM7wY4baX2y6
a=ice-options:trickle
a=fingerprint:sha-256 32:29:80:F0:30:CF:D5:1A:F8:F6:CB:74:BD:7B:E4:E0:53:CE:E9:0E:B7:3D:30:0E:9C:F1:E4:F7:0A:85:94:AA
a=setup:actpass
a=mid:0
a=extmap:1 urn:ietf:params:rtp-hdrext:toffset
a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
a=extmap:3 urn:3gpp:video-orientation
a=extmap:4 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
a=extmap:5 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay
a=extmap:6 http://www.webrtc.org/experiments/rtp-hdrext/video-content-type
a=extmap:7 http://www.webrtc.org/experiments/rtp-hdrext/video-timing
a=extmap:8 http://www.webrtc.org/experiments/rtp-hdrext/color-space
a=extmap:9 urn:ietf:params:rtp-hdrext:sdes:mid
a=extmap:10 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id
a=extmap:11 urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id
a=recvonly
a=rtcp-mux
a=rtcp-rsize
a=rtcp-xr:rcvr-rtt=all
a=rtpmap:102 H264/90000
a=rtcp-fb:102 goog-remb
a=rtcp-fb:102 transport-cc
a=rtcp-fb:102 ccm fir
a=rtcp-fb:102 nack
a=rtcp-fb:102 nack pli
a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f
a=rtpmap:103 rtx/90000
a=fmtp:103 apt=102
a=rtpmap:104 H264/90000
a=rtcp-fb:104 goog-remb
a=rtcp-fb:104 transport-cc
a=rtcp-fb:104 ccm fir
a=rtcp-fb:104 nack
a=rtcp-fb:104 nack pli
a=fmtp:104 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42001f
a=rtpmap:107 rtx/90000
a=fmtp:107 apt=104
a=rtpmap:108 H264/90000
a=rtcp-fb:108 goog-remb
a=rtcp-fb:108 transport-cc
a=rtcp-fb:108 ccm fir
a=rtcp-fb:108 nack
a=rtcp-fb:108 nack pli
a=fmtp:108 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
a=rtpmap:109 rtx/90000
a=fmtp:109 apt=108
a=rtpmap:114 H264/90000
a=rtcp-fb:114 goog-remb
a=rtcp-fb:114 transport-cc
a=rtcp-fb:114 ccm fir
a=rtcp-fb:114 nack
a=rtcp-fb:114 nack pli
a=fmtp:114 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42e01f
a=rtpmap:115 rtx/90000
a=fmtp:115 apt=114
a=rtpmap:116 H264/90000
a=rtcp-fb:116 goog-remb
a=rtcp-fb:116 transport-cc
a=rtcp-fb:116 ccm fir
a=rtcp-fb:116 nack
a=rtcp-fb:116 nack pli
a=fmtp:116 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f
a=rtpmap:117 rtx/90000
a=fmtp:117 apt=116
a=rtpmap:39 H264/90000
a=rtcp-fb:39 goog-remb
a=rtcp-fb:39 transport-cc
a=rtcp-fb:39 ccm fir
a=rtcp-fb:39 nack
a=rtcp-fb:39 nack pli
a=fmtp:39 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=4d001f
a=rtpmap:40 rtx/90000
a=fmtp:40 apt=39
a=rtpmap:41 H264/90000
a=rtcp-fb:41 goog-remb
a=rtcp-fb:41 transport-cc
a=rtcp-fb:41 ccm fir
a=rtcp-fb:41 nack
a=rtcp-fb:41 nack pli
a=fmtp:41 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=f4001f
a=rtpmap:42 rtx/90000
a=fmtp:42 apt=41
a=rtpmap:43 H264/90000
a=rtcp-fb:43 goog-remb
a=rtcp-fb:43 transport-cc
a=rtcp-fb:43 ccm fir
a=rtcp-fb:43 nack
a=rtcp-fb:43 nack pli
a=fmtp:43 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=f4001f
a=rtpmap:44 rtx/90000
a=fmtp:44 apt=43
a=rtpmap:118 H264/90000
a=rtcp-fb:118 goog-remb
a=rtcp-fb:118 transport-cc
a=rtcp-fb:118 ccm fir
a=rtcp-fb:118 nack
a=rtcp-fb:118 nack pli
a=fmtp:118 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f
a=rtpmap:119 rtx/90000
a=fmtp:119 apt=118
a=rtpmap:120 H264/90000
a=rtcp-fb:120 goog-remb
a=rtcp-fb:120 transport-cc
a=rtcp-fb:120 ccm fir
a=rtcp-fb:120 nack
a=rtcp-fb:120 nack pli
a=fmtp:120 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=64001f
a=rtpmap:121 rtx/90000
a=fmtp:121 apt=120
a=rtpmap:96 VP8/90000
a=rtcp-fb:96 goog-remb
a=rtcp-fb:96 transport-cc
a=rtcp-fb:96 ccm fir
a=rtcp-fb:96 nack
a=rtcp-fb:96 nack pli
a=rtpmap:97 rtx/90000
a=fmtp:97 apt=96
a=rtpmap:98 VP9/90000
a=rtcp-fb:98 goog-remb
a=rtcp-fb:98 transport-cc
a=rtcp-fb:98 ccm fir
a=rtcp-fb:98 nack
a=rtcp-fb:98 nack pli
a=fmtp:98 profile-id=0
a=rtpmap:99 rtx/90000
a=fmtp:99 apt=98
a=rtpmap:100 VP9/90000
a=rtcp-fb:100 goog-remb
a=rtcp-fb:100 transport-cc
a=rtcp-fb:100 ccm fir
a=rtcp-fb:100 nack
a=rtcp-fb:100 nack pli
a=fmtp:100 profile-id=2
a=rtpmap:101 rtx/90000
a=fmtp:101 apt=100
a=rtpmap:35 VP9/90000
a=rtcp-fb:35 goog-remb
a=rtcp-fb:35 transport-cc
a=rtcp-fb:35 ccm fir
a=rtcp-fb:35 nack
a=rtcp-fb:35 nack pli
a=fmtp:35 profile-id=1
a=rtpmap:36 rtx/90000
a=fmtp:36 apt=35
a=rtpmap:37 VP9/90000
a=rtcp-fb:37 goog-remb
a=rtcp-fb:37 transport-cc
a=rtcp-fb:37 ccm fir
a=rtcp-fb:37 nack
a=rtcp-fb:37 nack pli
a=fmtp:37 profile-id=3
a=rtpmap:38 rtx/90000
a=fmtp:38 apt=37
a=rtpmap:45 AV1/90000
a=rtcp-fb:45 goog-remb
a=rtcp-fb:45 transport-cc
a=rtcp-fb:45 ccm fir
a=rtcp-fb:45 nack
a=rtcp-fb:45 nack pli
a=fmtp:45 level-idx=5;profile=0;tier=0
a=rtpmap:46 rtx/90000
a=fmtp:46 apt=45
a=rtpmap:47 AV1/90000
a=rtcp-fb:47 goog-remb
a=rtcp-fb:47 transport-cc
a=rtcp-fb:47 ccm fir
a=rtcp-fb:47 nack
a=rtcp-fb:47 nack pli
a=fmtp:47 level-idx=5;profile=1;tier=0
a=rtpmap:48 rtx/90000
a=fmtp:48 apt=47
a=rtpmap:49 H265/90000
a=rtcp-fb:49 goog-remb
a=rtcp-fb:49 transport-cc
a=rtcp-fb:49 ccm fir
a=rtcp-fb:49 nack
a=rtcp-fb:49 nack pli
a=fmtp:49 level-id=180;profile-id=1;tier-flag=0;tx-mode=SRST
a=rtpmap:50 rtx/90000
a=fmtp:50 apt=49
a=rtpmap:51 H265/90000
a=rtcp-fb:51 goog-remb
a=rtcp-fb:51 transport-cc
a=rtcp-fb:51 ccm fir
a=rtcp-fb:51 nack
a=rtcp-fb:51 nack pli
a=fmtp:51 level-id=180;profile-id=2;tier-flag=0;tx-mode=SRST
a=rtpmap:52 rtx/90000
a=fmtp:52 apt=51
a=rtpmap:122 red/90000
a=rtpmap:123 rtx/90000
a=fmtp:123 apt=122
a=rtpmap:124 ulpfec/90000
a=rtpmap:53 flexfec-03/90000
a=rtcp-fb:53 goog-remb
a=rtcp-fb:53 transport-cc
a=fmtp:53 repair-window=10000000
"""#.replacingOccurrences(of: "\n", with: "\r\n")
