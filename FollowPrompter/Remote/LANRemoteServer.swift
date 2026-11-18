import Foundation
import Network

/// 局域网遥控通道（给安卓等非苹果设备用）。
///
/// iPad 在同一 Wi‑Fi 下开一个 TCP 服务，并用 Bonjour（mDNS）广播 `_fpremote._tcp`，
/// 安卓用 NsdManager 就能发现。消息是一行一条的 JSON（UTF‑8，以 `\n` 结尾）：
///
/// 遥控器 → iPad
/// - `{"type":"hello","name":"Pixel 8","code":"1234","version":1}` 连接后先发，配对码对了才接受后续消息
/// - `{"type":"command","command":"rereadSentence"}` 命令名同 `RemoteCommand`
/// - `{"type":"ping"}` 每 3 秒一次；iPad 10 秒收不到任何消息就断开
///
/// iPad → 遥控器
/// - `{"type":"welcome","host":"iPad","version":1}` / `{"type":"denied","reason":"…"}`
/// - `{"type":"status","status":{…RemoteStatus 的字段…}}` 状态变化时推送
/// - `{"type":"pong"}`
final class LANRemoteServer: @unchecked Sendable {
    static let serviceType = "_fpremote._tcp"
    static let preferredPort: UInt16 = 52819
    static let protocolVersion = 1

    struct Client: Equatable { let id: ObjectIdentifier; let name: String }

    /// 主线程回调
    var onCommand: ((RemoteCommand) -> Void)?
    var onClientsChange: (([Client]) -> Void)?
    var onPortChange: ((UInt16?) -> Void)?

    private let queue = DispatchQueue(label: "FollowPrompter.LANRemote")
    private let hostName: String
    private let code: String
    // 以下只在 queue 上访问
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Peer] = [:]
    private var lastStatus: Data?
    private var watchdog: DispatchSourceTimer?

    private final class Peer {
        let connection: NWConnection
        var buffer = Data()
        var name: String?
        var lastSeen = Date()
        let opened = Date()
        init(_ c: NWConnection) { connection = c }
        var authed: Bool { name != nil }
    }

    init(hostName: String, code: String) {
        self.hostName = hostName
        self.code = code
    }

    func start() {
        queue.async { self.listen(port: Self.preferredPort) }
    }

    func stop() {
        queue.async {
            self.watchdog?.cancel()
            self.watchdog = nil
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.connection.cancel() }
            self.connections.removeAll()
            self.notifyClients()
        }
    }

    func publish(_ status: RemoteStatus) {
        guard let data = Self.encode(["type": "status", "status": status]) else { return }
        queue.async {
            self.lastStatus = data
            for peer in self.connections.values where peer.authed { self.send(data, to: peer) }
        }
    }

    // MARK: 监听

    private func listen(port: UInt16?) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            if let port, let p = NWEndpoint.Port(rawValue: port) {
                l = try NWListener(using: params, on: p)
            } else {
                l = try NWListener(using: params)
            }
        } catch {
            if port != nil { listen(port: nil) }
            return
        }
        l.service = NWListener.Service(name: hostName, type: Self.serviceType)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            switch state {
            case .ready:
                let p = l.port?.rawValue
                DispatchQueue.main.async { self.onPortChange?(p) }
            case .failed:
                // 固定端口被占用时换一个随机端口（Bonjour 广播会带上实际端口）
                l.cancel()
                if self.listener === l {
                    self.listener = nil
                    if port != nil { self.listen(port: nil) }
                    DispatchQueue.main.async { self.onPortChange?(nil) }
                }
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
        startWatchdog()
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for peer in self.connections.values {
                let silent = now.timeIntervalSince(peer.lastSeen)
                // 没配对的 10 秒内必须发 hello；配对后 10 秒没动静（手机锁屏、离开 Wi‑Fi）就断开
                if silent > 10 || (!peer.authed && now.timeIntervalSince(peer.opened) > 10) {
                    self.drop(peer)
                }
            }
        }
        t.resume()
        watchdog = t
    }

    // MARK: 连接

    private func accept(_ c: NWConnection) {
        let peer = Peer(c)
        connections[ObjectIdentifier(peer)] = peer
        c.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .failed, .cancelled: self.drop(peer)
            default: break
            }
        }
        c.start(queue: queue)
        receive(peer)
    }

    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak peer] data, _, done, error in
            guard let self, let peer, self.connections[ObjectIdentifier(peer)] != nil else { return }
            if let data, !data.isEmpty {
                peer.buffer.append(data)
                peer.lastSeen = Date()
                while let nl = peer.buffer.firstIndex(of: 0x0A) {
                    let line = peer.buffer[peer.buffer.startIndex..<nl]
                    peer.buffer.removeSubrange(peer.buffer.startIndex...nl)
                    self.handle(Data(line), from: peer)
                }
                if peer.buffer.count > 64 * 1024 { self.drop(peer); return }
            }
            if done || error != nil { self.drop(peer) } else { self.receive(peer) }
        }
    }

    private func handle(_ line: Data, from peer: Peer) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "hello":
            guard (obj["code"] as? String) == code else {
                send(Self.encode(["type": "denied", "reason": "配对码不对"]), to: peer) { [weak self] in self?.drop(peer) }
                return
            }
            let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(40)) } ?? "遥控器"
            peer.name = name
            send(Self.encode(["type": "welcome", "host": hostName, "version": Self.protocolVersion]), to: peer)
            if let lastStatus { send(lastStatus, to: peer) }
            notifyClients()
        case "command":
            guard peer.authed, let raw = obj["command"] as? String, let cmd = RemoteCommand(rawValue: raw) else { return }
            DispatchQueue.main.async { self.onCommand?(cmd) }
        case "ping":
            send(Self.encode(["type": "pong"]), to: peer)
        default:
            break
        }
    }

    private func send(_ data: Data?, to peer: Peer, then: (() -> Void)? = nil) {
        guard let data else { return }
        peer.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.queue.async { self?.drop(peer) }
            }
            then.map { f in self?.queue.async(execute: f) }
        })
    }

    private func drop(_ peer: Peer) {
        guard connections.removeValue(forKey: ObjectIdentifier(peer)) != nil else { return }
        peer.connection.cancel()
        if peer.authed { notifyClients() }
    }

    private func notifyClients() {
        let list = connections.values.compactMap { p in p.name.map { Client(id: ObjectIdentifier(p), name: $0) } }
            .sorted { $0.name < $1.name }
        DispatchQueue.main.async { self.onClientsChange?(list) }
    }

    // MARK: 编码

    private static func encode(_ dict: [String: Any]) -> Data? {
        var obj = dict
        if let status = dict["status"] as? RemoteStatus,
           let data = try? JSONEncoder().encode(status),
           let json = try? JSONSerialization.jsonObject(with: data) {
            obj["status"] = json
        }
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        data.append(0x0A)
        return data
    }

    // MARK: 本机地址（手动连接时显示）

    static func wifiAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            candidates.append((String(cString: ifa.ifa_name), ip))
        }
        return candidates.first { $0.name == "en0" }?.ip ?? candidates.first { $0.name.hasPrefix("en") }?.ip ?? candidates.first?.ip
    }
}
