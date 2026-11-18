import Foundation
import MultipeerConnectivity
import Observation
import UIKit

// MARK: - 协议

enum RemoteCommand: String, Codable, CaseIterable {
    case toggle             // 开始 / 暂停
    case rereadSentence         // 重读本句
    case rereadParagraph        // 重读本段
    case previousSentence
    case nextSentence
    case restart            // 回到开头
    case faster, slower     // 匀速模式调速
}

struct RemoteStatus: Codable, Equatable {
    var title: String
    var mode: String
    var running: Bool
    var countdown: Int?
    var listening: Bool
    var progress: Double
    var elapsed: Int
    var current: String
    var next: String
    var rereadCount: Int
    var autoSpeed: Int
}

enum RemoteMessage: Codable, Equatable {
    case command(RemoteCommand)
    case status(RemoteStatus)
}

// MARK: - 底层连接（非隔离；所有回调都派发到主线程）

/// iPad 端广播（host），iPhone 端搜索（client）。走蓝牙 / 点对点 Wi‑Fi，不需要联网。
final class PeerLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let serviceType = "fprompt"

    let peerID: MCPeerID
    let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    var onStateChange: ((MCPeerID, MCSessionState) -> Void)?
    var onFound: ((MCPeerID) -> Void)?
    var onLost: ((MCPeerID) -> Void)?
    var onMessage: ((RemoteMessage) -> Void)?

    override init() {
        peerID = MCPeerID(displayName: UIDevice.current.name)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    func advertise() {
        let a = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
    }

    func browse() {
        let b = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    func invite(_ peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 10)
    }

    func send(_ message: RemoteMessage) {
        let peers = session.connectedPeers
        guard !peers.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
        advertiser = nil
        browser = nil
    }

    // MCSessionDelegate
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { self.onStateChange?(peerID, state) }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let msg = try? JSONDecoder().decode(RemoteMessage.self, from: data) else { return }
        DispatchQueue.main.async { self.onMessage?(msg) }
    }

    func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID,
                 certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    // MCNearbyServiceAdvertiserDelegate
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("遥控广播失败：\(error)")
    }

    // MCNearbyServiceBrowserDelegate
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { self.onFound?(peerID) }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.onLost?(peerID) }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("遥控搜索失败：\(error)")
    }
}

// MARK: - iPad 端

@MainActor @Observable
final class RemoteHost {
    private(set) var connectedCount = 0
    @ObservationIgnored var onCommand: ((RemoteCommand) -> Void)?
    @ObservationIgnored private var link: PeerLink?
    @ObservationIgnored private var lastSent: RemoteStatus?

    func start() {
        guard link == nil else { return }
        let l = PeerLink()
        l.onStateChange = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let link = self.link else { return }
                let n = link.session.connectedPeers.count
                if n > self.connectedCount { self.lastSent = nil }   // 新遥控器连上，下次强制推送状态
                self.connectedCount = n
            }
        }
        l.onMessage = { [weak self] msg in
            MainActor.assumeIsolated {
                if case .command(let c) = msg { self?.onCommand?(c) }
            }
        }
        l.advertise()
        link = l
    }

    func stop() {
        link?.stop()
        link = nil
        connectedCount = 0
        lastSent = nil
    }

    func publish(_ status: RemoteStatus) {
        guard connectedCount > 0, status != lastSent else { return }
        lastSent = status
        link?.send(.status(status))
    }
}

// MARK: - iPhone 端

@MainActor @Observable
final class RemoteClient {
    private(set) var found: [MCPeerID] = []
    private(set) var connected: MCPeerID?
    private(set) var connecting: MCPeerID?
    private(set) var status: RemoteStatus?
    @ObservationIgnored private var link: PeerLink?
    @ObservationIgnored private var autoReconnect = true

    var isConnected: Bool { connected != nil }

    func start() {
        guard link == nil else { return }
        let l = PeerLink()
        l.onFound = { [weak self] peer in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.found.contains(peer) { self.found.append(peer) }
                // 只发现一台 iPad 时自动连接
                if self.autoReconnect, self.connected == nil, self.connecting == nil, self.found.count == 1 {
                    self.connect(peer)
                }
            }
        }
        l.onLost = { [weak self] peer in
            MainActor.assumeIsolated { self?.found.removeAll { $0 == peer } }
        }
        l.onStateChange = { [weak self] peer, state in
            MainActor.assumeIsolated { self?.handle(peer: peer, state: state) }
        }
        l.onMessage = { [weak self] msg in
            MainActor.assumeIsolated {
                if case .status(let s) = msg { self?.status = s }
            }
        }
        l.browse()
        link = l
    }

    func connect(_ peer: MCPeerID) {
        autoReconnect = true
        connecting = peer
        link?.invite(peer)
    }

    func disconnect() {
        autoReconnect = false
        link?.session.disconnect()
        connected = nil
        connecting = nil
        status = nil
    }

    func send(_ command: RemoteCommand) {
        link?.send(.command(command))
    }

    private func handle(peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            connected = peer
            connecting = nil
        case .connecting:
            connecting = peer
        case .notConnected:
            if connecting == peer { connecting = nil }
            guard connected == peer || connected == nil else { return }
            connected = nil
            status = nil
            // 断线（iPad 退出提词页、走出范围）后，若对方仍可见则自动重连
            if autoReconnect, found.contains(peer) {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.connected == nil, self.connecting == nil, self.found.contains(peer) else { return }
                    self.connect(peer)
                }
            }
        @unknown default:
            break
        }
    }
}
