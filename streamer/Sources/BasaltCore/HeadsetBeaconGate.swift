import Foundation

/// `burst` events at once, then one more per `interval`.
struct RefillingAllowance {
    let burst: Int
    let intervalNanoseconds: UInt64
    private var available: Int
    private var refilledAt: UInt64?

    init(burst: Int, intervalNanoseconds: UInt64) {
        self.burst = burst
        self.intervalNanoseconds = intervalNanoseconds
        available = burst
    }

    mutating func take(at now: UInt64) -> Bool {
        if let last = refilledAt {
            if now > last, intervalNanoseconds > 0 {
                let earned = (now - last) / intervalNanoseconds
                if earned >= UInt64(burst - available) {
                    available = burst
                    refilledAt = now
                } else if earned > 0 {
                    available += Int(earned)
                    refilledAt = last + earned * intervalNanoseconds
                }
            }
        } else {
            refilledAt = now
        }
        guard available > 0 else { return false }
        available -= 1
        return true
    }
}

/// What tells one version of the trust file from the next without reading it.
struct TrustFileSignature: Equatable {
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    /// Nil when the file is missing or cannot be examined.
    static func of(_ file: URL) -> TrustFileSignature? {
        var information = stat()
        guard stat(file.path, &information) == 0 else { return nil }
        return TrustFileSignature(
            inode: UInt64(information.st_ino), size: Int64(information.st_size),
            modifiedSeconds: information.st_mtimespec.tv_sec,
            modifiedNanoseconds: information.st_mtimespec.tv_nsec)
    }
}

/// Decides, for every discovery beacon, whether its hostname is approved, and
/// reports unapproved names to the session log so the app can ask the user.
///
/// Anyone on the network can send beacons, with any name, as fast as the
/// network carries them. So every cost here has a ceiling that does not
/// depend on the number of packets or names:
/// - the trust file is looked at a limited number of times per second and
///   read again only when it changed (approval and Forget still apply on the
///   next beacon of a headset, which arrives about once a second);
/// - a name is reported once while it is remembered, and only the newest
///   `maximumRememberedRequests` reported names are remembered;
/// - all names together get `requestBurst` log lines, then one per
///   `requestRefillNanoseconds`; what was left out is counted in one line
///   per `summaryIntervalNanoseconds`.
///
/// Accessed on discovery's serial queue. The hostname identity matches ALVR's
/// own hostname trust; it is not cryptographic and can be impersonated on a LAN.
public final class HeadsetBeaconGate {
    static let maximumRememberedRequests = 64
    static let requestBurst = 8
    static let requestRefillNanoseconds: UInt64 = 10_000_000_000
    static let summaryIntervalNanoseconds: UInt64 = 10_000_000_000
    static let trustCheckBurst = 20
    static let trustCheckRefillNanoseconds: UInt64 = 50_000_000
    /// The file is read again this often even when it looks unchanged: on a
    /// network or FAT disk the signature of a replaced file can stay the same.
    static let trustRefreshNanoseconds: UInt64 = 2_000_000_000
    /// The log line the app reads requests from starts with "Headset request: ".
    /// This one must not: it names no headset.
    static let hiddenRequestsLogPrefix = "Headset requests hidden: "

    private let file: URL?
    private let now: () -> UInt64
    private let signature: (URL) -> TrustFileSignature?
    private let read: (URL) throws -> [String]

    private var trustChecks = RefillingAllowance(
        burst: trustCheckBurst, intervalNanoseconds: trustCheckRefillNanoseconds)
    private var trustLoaded = false
    /// Nil while the file cannot be read: nobody is trusted then.
    private var trusted: Set<String>?
    private var trustSignature: TrustFileSignature?
    private var trustReadAt: UInt64 = 0

    private var requestLines = RefillingAllowance(
        burst: requestBurst, intervalNanoseconds: requestRefillNanoseconds)
    private var reported = Set<String>()
    private var reportedOrder = [String]()
    private var hiddenRequests = 0
    private var lastHiddenSummary: UInt64?

    public convenience init(file: URL?) {
        self.init(file: file,
                  now: { DispatchTime.now().uptimeNanoseconds },
                  signature: TrustFileSignature.of,
                  read: { try HeadsetTrustStore(file: $0).load() })
    }

    init(file: URL?,
         now: @escaping () -> UInt64,
         signature: @escaping (URL) -> TrustFileSignature?,
         read: @escaping (URL) throws -> [String]) {
        self.file = file
        self.now = now
        self.signature = signature
        self.read = read
    }

    var rememberedRequestCount: Int { reported.count }

    public func accept(hostname: String, ip: String, report: (String) -> Void) -> Bool {
        guard let file else { return true } // Preserve the standalone CLI default.
        guard HeadsetTrustStore.validHostname(hostname) else { return false }
        let now = now()
        if isTrusted(hostname, file: file, now: now) { return true }
        if !reported.contains(hostname) {
            if requestLines.take(at: now) {
                remember(hostname)
                report("Headset request: \(hostname) at \(ip)")
            } else {
                hiddenRequests += 1
            }
        }
        if hiddenRequests > 0,
           lastHiddenSummary.map({ now >= $0 && now - $0 >= Self.summaryIntervalNanoseconds }) ?? true {
            report(Self.hiddenRequestsLogPrefix
                + "\(hiddenRequests) beacon(s) from other unapproved names were not shown "
                + "(too many different names at once)")
            hiddenRequests = 0
            lastHiddenSummary = now
        }
        return false
    }

    private func isTrusted(_ hostname: String, file: URL, now: UInt64) -> Bool {
        if !trustLoaded || trustChecks.take(at: now) {
            let current = signature(file)
            if !trustLoaded || current != trustSignature
                || now < trustReadAt || now - trustReadAt >= Self.trustRefreshNanoseconds {
                trusted = (try? read(file)).map(Set.init)
                trustSignature = current
                trustReadAt = now
                trustLoaded = true
            }
        }
        return trusted?.contains(hostname) == true
    }

    private func remember(_ hostname: String) {
        reported.insert(hostname)
        reportedOrder.append(hostname)
        if reportedOrder.count > Self.maximumRememberedRequests {
            reported.remove(reportedOrder.removeFirst())
        }
    }
}

/// Which trusted clients were offered to the session recently. One entry per
/// "hostname@address"; the address of a UDP packet is the sender's own claim,
/// so the table has a size limit as well.
struct RecentBeaconClients {
    static let capacity = 256
    private var lastOffered: [String: Date] = [:]

    var count: Int { lastOffered.count }

    /// True at most once per `repeatInterval` for each key. With the table
    /// full of keys still inside their interval, a new key has to wait.
    mutating func shouldOffer(_ key: String, at now: Date, repeatInterval: TimeInterval) -> Bool {
        if let last = lastOffered[key] {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= 0, elapsed < repeatInterval { return false }
        } else if lastOffered.count >= Self.capacity {
            lastOffered = lastOffered.filter {
                let elapsed = now.timeIntervalSince($0.value)
                return elapsed >= 0 && elapsed < repeatInterval
            }
            guard lastOffered.count < Self.capacity else { return false }
        }
        lastOffered[key] = now
        return true
    }
}
