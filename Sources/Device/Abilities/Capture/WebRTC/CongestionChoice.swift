import Foundation

/// Which congestion control a viewer runs, as the WHEP switch spells it
/// (`?congestion=transport-cc|remb|off`). The method asked for, when the offer
/// can carry it, else none; with nothing asked, transport-cc if offered, else
/// REMB if offered, else none. transport-cc is the default: it measures the link
/// itself, and since it stopped reading jitter as congestion it gave the best
/// picture on a phone over Tailscale (2026-11-20), where REMB started soft and
/// ramped slowly.
public enum CongestionChoice: String, Sendable {
    case transportWide = "transport-cc"
    case receiverEstimate = "remb"
    case off

    public static func control(asked: CongestionChoice?, offer: SessionDescription, ceiling: Int) -> any CongestionControl {
        let transportWide: (any CongestionControl)? = offer.transportWideSequenceID.map {
            TransportWideControl(extensionID: $0, payloadType: offer.payloadType, ceiling: ceiling)
        }
        let receiverEstimate: (any CongestionControl)? = offer.absSendTimeID.map {
            ReceiverEstimateControl(extensionID: $0, payloadType: offer.payloadType, ceiling: ceiling)
        }
        let none: any CongestionControl = FixedBitrate()
        switch asked {
        case .transportWide?: return transportWide ?? none
        case .receiverEstimate?: return receiverEstimate ?? none
        case .off?: return none
        case nil: return transportWide ?? receiverEstimate ?? none
        }
    }
}
