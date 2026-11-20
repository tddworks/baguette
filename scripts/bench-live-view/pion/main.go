// pion-whep: the bench's reference WebRTC sender, to compare against baguette's own.
//
// The same encoder — `baguette stream --format avcc` at serve's settings — sent
// through Pion (github.com/pion/webrtc) with Pion's Google Congestion Control
// and pacer. Pion's target bitrate retunes the encoder through the stream's own
// stdin (`set_bitrate`), with the rule baguette's viewer uses (at most once a
// second, only on a change over 10 %); a PLI or FIR asks it for a keyframe.
// So the encoder, screen and page are the same, and only the WebRTC sender
// differs.
//
//	pion-whep -baguette <path> -udid <UDID> [-listen 127.0.0.1:8890]
//
// POST /whep          an SDP offer → 201, the answer, Location: /whep/<id>
// DELETE /whep/<id>   hang that viewer up
//
// One viewer at a time is what a bench run needs; each has its own encoder.
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/cc"
	"github.com/pion/interceptor/pkg/gcc"
	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

const (
	startBitrate = 8_000_000 // serve's default, and baguette's ceiling
	floorBitrate = 300_000   // baguette's BandwidthEstimate floor
	h264Fmtp     = "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64001f"
)

var (
	baguette = flag.String("baguette", "", "the baguette binary")
	udid     = flag.String("udid", "", "the simulator to stream")
	listen   = flag.String("listen", "127.0.0.1:8890", "where to serve WHEP")
)

var (
	mu      sync.Mutex
	viewers = map[string]*viewer{}
	nextID  = 0
)

func main() {
	flag.Parse()
	if *baguette == "" || *udid == "" {
		log.Fatal("usage: pion-whep -baguette <path> -udid <UDID> [-listen addr]")
	}
	http.HandleFunc("/whep", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST an SDP offer", http.StatusMethodNotAllowed)
			return
		}
		offer, _ := io.ReadAll(io.LimitReader(r.Body, 64*1024))
		id, answer, err := admit(string(offer))
		if err != nil {
			log.Printf("[pion] refused: %v", err)
			http.Error(w, err.Error(), http.StatusUnprocessableEntity)
			return
		}
		w.Header().Set("Content-Type", "application/sdp")
		w.Header().Set("Location", "/pion/whep/"+id)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, answer)
	})
	http.HandleFunc("/whep/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete {
			http.Error(w, "DELETE a viewer", http.StatusMethodNotAllowed)
			return
		}
		id := strings.TrimPrefix(r.URL.Path, "/whep/")
		mu.Lock()
		v := viewers[id]
		mu.Unlock()
		if v == nil {
			http.Error(w, "unknown viewer: "+id, http.StatusNotFound)
			return
		}
		v.hangUp()
		w.WriteHeader(http.StatusNoContent)
	})
	log.Printf("[pion] WHEP on http://%s/whep for %s", *listen, *udid)
	log.Fatal(http.ListenAndServe(*listen, nil))
}

// One browser: its peer connection, its own encoder, and Pion's estimate of the link.
type viewer struct {
	id        string
	pc        *webrtc.PeerConnection
	stream    *exec.Cmd
	control   io.WriteCloser
	estimator cc.BandwidthEstimator
	once      sync.Once
	done      chan struct{}

	controlMu  sync.Mutex
	bitrate    int
	lastRetune time.Time
}

func admit(offer string) (string, string, error) {
	media := &webrtc.MediaEngine{}
	feedback := []webrtc.RTCPFeedback{
		{Type: "nack"}, {Type: "nack", Parameter: "pli"}, {Type: "ccm", Parameter: "fir"}, {Type: webrtc.TypeRTCPFBTransportCC},
	}
	if err := media.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType: webrtc.MimeTypeH264, ClockRate: 90_000, SDPFmtpLine: h264Fmtp, RTCPFeedback: feedback,
		},
		PayloadType: 112,
	}, webrtc.RTPCodecTypeVideo); err != nil {
		return "", "", err
	}
	registry := &interceptor.Registry{}
	estimators := make(chan cc.BandwidthEstimator, 1)
	controller, err := cc.NewInterceptor(func() (cc.BandwidthEstimator, error) {
		return gcc.NewSendSideBWE(
			gcc.SendSideBWEInitialBitrate(startBitrate),
			gcc.SendSideBWEMaxBitrate(startBitrate),
			gcc.SendSideBWEMinBitrate(floorBitrate))
	})
	if err != nil {
		return "", "", err
	}
	controller.OnNewPeerConnection(func(_ string, e cc.BandwidthEstimator) { estimators <- e })
	registry.Add(controller)
	if err := webrtc.ConfigureTWCCHeaderExtensionSender(media, registry); err != nil {
		return "", "", err
	}
	if err := webrtc.RegisterDefaultInterceptors(media, registry); err != nil {
		return "", "", err
	}
	settings := webrtc.SettingEngine{}
	settings.SetIncludeLoopbackCandidate(true)
	// Fixed ports, so the bench's impair.sh shapes Pion's media as it does baguette's.
	if err := settings.SetEphemeralUDPPortRange(8195, 8199); err != nil {
		return "", "", err
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(media), webrtc.WithInterceptorRegistry(registry), webrtc.WithSettingEngine(settings))
	pc, err := api.NewPeerConnection(webrtc.Configuration{BundlePolicy: webrtc.BundlePolicyMaxBundle})
	if err != nil {
		return "", "", err
	}
	estimator := <-estimators

	track, err := webrtc.NewTrackLocalStaticSample(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90_000, SDPFmtpLine: h264Fmtp}, "video", "baguette")
	if err != nil {
		pc.Close()
		return "", "", err
	}
	sender, err := pc.AddTrack(track)
	if err != nil {
		pc.Close()
		return "", "", err
	}
	if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer}); err != nil {
		pc.Close()
		return "", "", err
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		pc.Close()
		return "", "", err
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		pc.Close()
		return "", "", err
	}
	<-gathered

	mu.Lock()
	nextID++
	v := &viewer{id: fmt.Sprint(nextID), pc: pc, estimator: estimator, done: make(chan struct{}), bitrate: startBitrate}
	viewers[v.id] = v
	mu.Unlock()

	if err := v.startStream(track); err != nil {
		v.hangUp()
		return "", "", err
	}
	go v.readFeedback(sender)
	go v.followEstimate()
	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		log.Printf("[pion] viewer %s %s", v.id, s)
		switch s {
		case webrtc.PeerConnectionStateConnected:
			v.command(`{"cmd":"force_idr"}`)
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed, webrtc.PeerConnectionStateDisconnected:
			v.hangUp()
		}
	})
	return v.id, pc.LocalDescription().SDP, nil
}

// The encoder, as `baguette stream` runs it for the MediaMTX spike: its avcc
// frames become Annex-B access units on the track.
func (v *viewer) startStream(track *webrtc.TrackLocalStaticSample) error {
	v.stream = exec.Command(*baguette, "stream", "--udid", *udid, "--format", "avcc",
		"--fps", "60", "--bitrate", fmt.Sprint(startBitrate), "--scale", "1")
	stdin, err := v.stream.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := v.stream.StdoutPipe()
	if err != nil {
		return err
	}
	v.control = stdin
	if err := v.stream.Start(); err != nil {
		return err
	}
	go func() {
		err := pump(bufio.NewReaderSize(stdout, 1<<20), track)
		log.Printf("[pion] viewer %s stream ended: %v", v.id, err)
		v.hangUp()
	}()
	return nil
}

// One envelope: [u32 length][u8 tag][payload]. Tag 1 the avcC record, 2 a
// keyframe, 3 a delta frame, both AVCC length-prefixed NAL units.
func pump(r *bufio.Reader, track *webrtc.TrackLocalStaticSample) error {
	startCode := []byte{0, 0, 0, 1}
	var params []byte
	last := time.Now()
	for {
		var header [4]byte
		if _, err := io.ReadFull(r, header[:]); err != nil {
			return err
		}
		chunk := make([]byte, binary.BigEndian.Uint32(header[:]))
		if _, err := io.ReadFull(r, chunk); err != nil {
			return err
		}
		if len(chunk) == 0 {
			continue
		}
		tag, payload := chunk[0], chunk[1:]
		switch {
		case tag == 1:
			params = parameterSets(payload, startCode)
		case (tag == 2 || tag == 3) && params != nil:
			var frame []byte
			if tag == 2 {
				frame = append(frame, params...)
			}
			for i := 0; i+4 <= len(payload); {
				n := int(binary.BigEndian.Uint32(payload[i:]))
				if i+4+n > len(payload) {
					break
				}
				frame = append(append(frame, startCode...), payload[i+4:i+4+n]...)
				i += 4 + n
			}
			now := time.Now()
			if err := track.WriteSample(media.Sample{Data: frame, Duration: now.Sub(last)}); err != nil && !errors.Is(err, io.ErrClosedPipe) {
				return err
			}
			last = now
		}
	}
}

// The SPS and PPS of an avcC record (ISO 14496-15 5.2.4.1), as Annex-B:
// byte 5 counts the SPSs (low 5 bits), then one byte counts the PPSs.
func parameterSets(record []byte, startCode []byte) []byte {
	var out []byte
	i := 5
	read := func() bool {
		if i+2 > len(record) {
			return false
		}
		n := int(binary.BigEndian.Uint16(record[i:]))
		if i+2+n > len(record) {
			return false
		}
		out = append(append(out, startCode...), record[i+2:i+2+n]...)
		i += 2 + n
		return true
	}
	if i >= len(record) {
		return nil
	}
	sps := int(record[i] & 0x1F)
	i++
	for ; sps > 0; sps-- {
		if !read() {
			return nil
		}
	}
	if i >= len(record) {
		return nil
	}
	pps := int(record[i])
	i++
	for ; pps > 0; pps-- {
		if !read() {
			return nil
		}
	}
	return out
}

// RTCP through the interceptors (NACK answering, transport-cc into GCC); a
// lost picture asks the encoder for a keyframe.
func (v *viewer) readFeedback(sender *webrtc.RTPSender) {
	for {
		packets, _, err := sender.ReadRTCP()
		if err != nil {
			return
		}
		for _, p := range packets {
			switch p.(type) {
			case *rtcp.PictureLossIndication, *rtcp.FullIntraRequest:
				v.command(`{"cmd":"force_idr"}`)
			}
		}
	}
}

// Pion's target, applied as baguette's viewer applies its own: at most once a
// second, and only when it moves by more than 10 %.
func (v *viewer) followEstimate() {
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-v.done:
			return
		case <-tick.C:
		}
		target := v.estimator.GetTargetBitrate()
		v.controlMu.Lock()
		current, since := v.bitrate, time.Since(v.lastRetune)
		v.controlMu.Unlock()
		change := float64(target-current) / float64(current)
		if since < time.Second || (change <= 0.10 && change >= -0.10) {
			continue
		}
		log.Printf("[pion] retune %d → %d kbps", current/1000, target/1000)
		line, _ := json.Marshal(map[string]any{"cmd": "set_bitrate", "bps": target})
		v.command(string(line))
		v.controlMu.Lock()
		v.bitrate, v.lastRetune = target, time.Now()
		v.controlMu.Unlock()
	}
}

func (v *viewer) command(line string) {
	v.controlMu.Lock()
	defer v.controlMu.Unlock()
	if v.control != nil {
		_, _ = io.WriteString(v.control, line+"\n")
	}
}

func (v *viewer) hangUp() {
	v.once.Do(func() {
		close(v.done)
		mu.Lock()
		delete(viewers, v.id)
		mu.Unlock()
		v.controlMu.Lock()
		if v.control != nil {
			v.control.Close()
			v.control = nil
		}
		v.controlMu.Unlock()
		if v.stream != nil && v.stream.Process != nil {
			_ = v.stream.Process.Kill()
			_ = v.stream.Wait()
		}
		_ = v.pc.Close()
		log.Printf("[pion] viewer %s hung up", v.id)
	})
}
