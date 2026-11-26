import Foundation
import SystemConfiguration
import BasaltBottleKit
import BasaltCore

/// Replaces personal and device identifiers in diagnostic text before it can
/// leave the Mac: the home folder and user names, the data and app folders,
/// disk names, this Mac's names, email addresses, Steam IDs, headset and
/// Bonjour host names, MAC and IP addresses (loopback is kept), long hex
/// tokens such as the control-socket token, ADB serials, `account=`-style
/// values, and the names the streamer prints for audio devices and the
/// headset. Game, bottle and profile names, versions, numbers and error
/// texts stay.
public struct DiagnosticRedactor: Sendable {
    public let homeDirectory: String
    public let userName: String
    /// Shown as `[data folder]` and `[app folder]`: the folders above them
    /// are the person's own layout, often on a disk that carries their name.
    public let dataFolder: String?
    public let appFolder: String?
    /// nil: this Mac's own names.
    let hostNames: [String]?
    /// nil: the disks connected when a text is redacted.
    let volumeNames: [String]?

    /// The defaults describe this Mac and the folders the app was started
    /// with; pass `dataFolder` when the person chose another one.
    public init(homeDirectory: String = NSHomeDirectory(), userName: String = NSUserName(),
                dataFolder: String? = ProcessInfo.processInfo.environment["BASALT_DATA_DIR"],
                appFolder: String? = ProcessInfo.processInfo.environment["BASALT_REPO_ROOT"],
                hostNames: [String]? = nil, volumeNames: [String]? = nil) {
        self.homeDirectory = Self.withoutTrailingSlashes(homeDirectory)
        self.userName = userName
        self.dataFolder = dataFolder.map(Self.withoutTrailingSlashes)
        self.appFolder = appFolder.map(Self.withoutTrailingSlashes)
        self.hostNames = hostNames
        self.volumeNames = volumeNames
    }

    /// Plain text: a log, or one value of a report before it is rendered.
    public func redact(_ text: String) -> String {
        // Copy and Save can also receive a log that is itself JSON.
        let first = text.first { !$0.isWhitespace }
        let isJSON = (first == "\"" || first == "[" || first == "{")
            && (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil
        return redactIdentifiers(in: Self.redactStreamerLines(in: text), preservingJSON: isJSON)
    }

    /// Every rule except the streamer's own lines. When redacting rendered
    /// JSON, keep the enclosing string delimiters and escaped line breaks.
    func redactIdentifiers(in text: String, preservingJSON: Bool = false) -> String {
        var value = text
        for (expression, placeholder) in folderRules() {
            value = Self.replace(expression, in: value, with: placeholder)
        }
        value = redactDiskNames(in: value)
        // macOS-style paths outside the home folder and Wine's
        // drive_c/users/<name>, with any run of separators: a Wine debug
        // string doubles its backslashes and JSON doubles them again.
        if !userName.isEmpty, let user = try? NSRegularExpression(
            pattern: #"(?i)([/\\]users[/\\]+)"# + Self.spellings(of: userName) + Self.nameEnd) {
            value = Self.replace(user, in: value, with: "$1[user]")
        }
        // Another account's folder, or a bottle copied from another Mac.
        value = Self.replaceGroup(2, of: Self.anyUser, in: value) { name in
            ["shared", "public"].contains(name.lowercased()) ? nil : "[user]"
        }
        value = Self.replace(Self.temporaryFolder, in: value, with: "$1[user]")
        if let hosts = hostRule() {
            value = Self.replace(hosts, in: value, with: "[host]")
        }
        for (expression, template) in Self.fixedRules {
            value = Self.replace(expression, in: value, with: template)
        }
        value = Self.replaceMatches(Self.ipv4, in: value) { address in
            address.hasPrefix("127.") || address == "0.0.0.0" ? nil : "[ipv4]"
        }
        value = Self.replaceMatches(Self.ipv6, in: value) { address in
            let bare = address.split(separator: "%").first.map(String.init) ?? address
            return bare == "::" || bare == "::1" ? nil : "[ipv6]"
        }
        value = Self.replace(Self.token, in: value, with: "[token]")
        // UUIDs (session IDs, temporary file names) and the time stamp in a
        // recording's file name identify nothing, but their digits and
        // letters look like a serial: match and keep them whole.
        value = Self.replaceMatches(Self.uuidOrSerial, in: value) { match in
            match.contains("-") || Self.isTimeStamp(match) ? nil : "[serial]"
        }
        value = Self.replace(preservingJSON ? Self.jsonAccount : Self.account,
                             in: value, with: "$1$2$3$4$5[redacted]$5")
        return value
    }

    // MARK: The streamer's own lines

    /// Lines of basalt-streamer that print a name with no diagnostic use: a
    /// CoreAudio device ("Ada's AirPods"), the headset's own name, a USB
    /// serial of any shape; and the Windows user and computer an Unreal
    /// game's log names. Such a name can hold any character and may run
    /// to the end of its line, so these rules read plain log lines only,
    /// never rendered JSON or a Markdown table.
    static func redactStreamerLines(in text: String) -> String {
        var value = text
        for expression in audioDeviceLines {
            value = replaceGroup(1, of: expression, in: value) { DiagnosticReport.audioCategory($0) }
        }
        for expression in audioDeviceListLines {
            value = replaceGroup(1, of: expression, in: value) { names in
                names.components(separatedBy: ", ").map { DiagnosticReport.audioCategory($0) }
                    .joined(separator: ", ")
            }
        }
        value = replace(headsetNameLine, in: value, with: "$1[headset]$2")
        value = replace(unrealUserLine, in: value, with: "$1[user]")
        value = replace(unrealComputerLine, in: value, with: "$1[host]")
        return replace(usbSerialLine, in: value, with: "$1[serial]$2")
    }

    /// Group 1 is the device name. The texts are those of
    /// BasaltStreamer/App.swift and BasaltCore/GameAudioCapture.swift.
    private static let audioDeviceLines = [
        #"Game audio output routed to (.+) for this session"#,
        #"Game audio capture ready: (.+), 48000 Hz stereo PCM16"#,
        #"game audio: (.+), 48 kHz stereo PCM16"#,
        #"BASALT_GAME_AUDIO=mac replaces (.+) with the Mac's own output"#,
        #"(?m)Restored Mac audio output to (.+)$"#,
        #"(?m)No real Mac audio output found; output remains on (.+)$"#,
        #"No CoreAudio input device contains '(.+)'; available: "#,
        #"Audio device name '(.+)' is ambiguous: "#,
        #"Could not set '(.+)' to \d+ Hz "#,
        #"'(.+)' did not switch to \d+ Hz within"#,
        #"CoreAudio input '(.+)' (?:cannot also receive application output|is not available to AVFoundation)"#,
        #"Could not open '(.+)': .*Grant Microphone access"#,
        #"Could not attach '(.+)' to audio capture"#,
        #"Could not configure PCM output for '(.+)'"#,
        #"Could not start audio capture from '(.+)'"#,
        // --list-audio-devices
        #"(?m)^(.+)\t\d+ Hz$"#,
    ].map(regex)

    /// Group 1 is a list of device names, joined by ", ".
    private static let audioDeviceListLines = [
        #"(?m)No CoreAudio input device contains '.+'; available: (.+)$"#,
        #"(?m)Audio device name '.+' is ambiguous: (.+)$"#,
    ].map(regex)

    private static let headsetNameLine = regex(
        #"(ALVR control accepted by ').*(': StreamConfig sent)"#)

    private static let usbSerialLine = regex(#"(USB Quest )\S+( is authorized)"#)

    /// Unreal names them as Wine reports them, which takes both from the
    /// Mac: the rest of the line is the name, quoted or not.
    private static let unrealUserLine = regex(#"(?m)(LogInit: User: ).*$"#)
    private static let unrealComputerLine = regex(#"(?m)(LogInit: Computer: ).*$"#)

    // MARK: Folders, disks and this Mac's names

    /// Where a file or host name starts and ends: `/Users/adam` is not the
    /// folder of `ada`.
    private static let nameStart = #"(?<![\p{L}\p{N}._%-])"#
    private static let nameEnd = #"(?![\p{L}\p{N}._%-])"#

    private static func withoutTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// A pattern for one name as text may spell it: as given, composed or
    /// decomposed (file systems differ on "é"), and percent-encoded as in a
    /// file URL.
    private static func spellings(of name: String) -> String {
        var forms = [name, name.precomposedStringWithCanonicalMapping,
                     name.decomposedStringWithCanonicalMapping]
        forms += forms.compactMap { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) }
        // Swift calls the composed and the decomposed form equal; the
        // pattern matches code units, so both are kept.
        var distinct = [String]()
        for form in forms
        where !distinct.contains(where: { $0.unicodeScalars.elementsEqual(form.unicodeScalars) }) {
            distinct.append(form)
        }
        return "(?:" + distinct.sorted { $0.utf16.count > $1.utf16.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
    }

    /// The data and app folders, then the home folder, the longest path
    /// first: the data folder is usually inside one of the other two.
    private func folderRules() -> [(NSRegularExpression, String)] {
        var rules = [(length: Int, pattern: String, placeholder: String)]()
        for (folder, placeholder) in [(dataFolder, "[data folder]"), (appFolder, "[app folder]")] {
            guard let folder, folder.hasPrefix("/") else { continue }
            let names = folder.split(separator: "/")
            // One name under the root is too little to tell a folder by.
            guard names.count > 1 else { continue }
            // Wine spells a host path as `Z:\Volumes\…`.
            rules.append((folder.count, "(?i)" + Self.nameStart + #"(?:[A-Z]:[/\\]+|[/\\])"#
                + names.map { Self.spellings(of: String($0)) }.joined(separator: #"[/\\]+"#)
                + Self.nameEnd, placeholder))
        }
        if homeDirectory.count > 1 {
            // Wine's `Z:/Users/ada` is left to the user rule, as `Z:\Users\ada` is.
            rules.append((homeDirectory.count, "(?<![A-Za-z]:)" + homeDirectory
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { Self.spellings(of: String($0)) }.joined(separator: "/") + Self.nameEnd, "~"))
        }
        return rules.sorted { $0.length > $1.length }.compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern)).map { ($0, rule.placeholder) }
        }
    }

    /// Matches the game root before other path rules can change parts of it.
    static func gameFolderRule(for path: String) -> NSRegularExpression? {
        let names = path.split(separator: "/")
        guard !names.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: "(?i)" + nameStart + #"(?:Z:)?[/\\]+"#
            + names.map { spellings(of: String($0)) }.joined(separator: #"[/\\]+"#) + nameEnd)
    }

    /// `/Volumes/<name>` keeps the rest of the path. Connected disks and
    /// the disks of the app's own folders are known by name, spaces
    /// included; any other name runs to the next separator.
    private func redactDiskNames(in text: String) -> String {
        var names = volumeNames
            ?? ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [])
        for folder in [dataFolder, appFolder, homeDirectory].compactMap({ $0 }) {
            let parts = folder.split(separator: "/")
            if parts.count > 1, parts[0] == "Volumes" { names.append(String(parts[1])) }
        }
        names = names.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var value = text
        if !names.isEmpty, let known = try? NSRegularExpression(
            pattern: #"(?i)([/\\]Volumes[/\\]+)(?:"#
                + names.map(Self.spellings(of:)).joined(separator: "|") + ")" + Self.nameEnd) {
            value = Self.replace(known, in: value, with: "$1[disk]")
        }
        value = Self.replace(Self.quotedDisk, in: value, with: "$1[disk]")
        return Self.replace(Self.anyDisk, in: value, with: "$1[disk]")
    }

    /// A disk the app does not know, as a whole quoted value (a JSON string
    /// that is the disk's own path): the name runs to the closing quote.
    private static let quotedDisk = regex(
        #"(?i)(?<=")((?:[A-Z]:)?[/\\]+Volumes[/\\]+)(?!\[disk\])[^/\\\r\n"]+(?=\\?")"#)

    /// A disk the app does not know: up to the next separator on the line,
    /// or one word when the path ends with the name. Punctuation that ends a
    /// path in a sentence ends the name too, and so does a space before the
    /// separator (another path begins there); an apostrophe inside a word
    /// ("Ada's SSD") does not.
    private static let anyDisk = regex(
        #"(?i)([/\\]Volumes[/\\]+)(?!\[disk\])"#
            + #"(?:(?:[^/\\\r\n"';,:=()<>|]|'(?=\p{L}))+?(?<!\s)(?=[/\\])"#
            + #"|(?:[^/\\\s"';,:=()<>|]|'(?=\p{L}))+)"#)

    /// The whole folder name after `users`, up to the next separator: a
    /// Windows user's may hold spaces, apostrophes and brackets ("Jane Doe").
    /// Only what no Windows name holds ends it early, a quote among them,
    /// so that rendered JSON stays valid; a space before the end is kept.
    private static let anyUser = regex(#"(?i)([/\\]users[/\\]+)([^/\\"<>|:*?\r\n\t]*[^/\\"<>|:*?\s])"#)

    /// The per-user temporary and cache root, `/var/folders/xx/<28 characters>`,
    /// is the same for a user on every start.
    private static let temporaryFolder = regex(
        #"((?:/private)?/var/folders/)[A-Za-z0-9_+]{2}/[A-Za-z0-9_+]{10,}"#)

    /// This Mac's names as whole words, in any case: Wine prints the
    /// computer name in capitals.
    private func hostRule() -> NSRegularExpression? {
        var names = [String]()
        for name in hostNames ?? Self.thisMacNames() {
            let name = name.trimmingCharacters(in: .whitespaces)
            // "Adas-Mac-mini.local" also goes by its first label, and
            // "Ada’s Mac mini" is typed with either apostrophe.
            names += [name, String(name.prefix { $0 != "." }),
                      name.replacingOccurrences(of: "’", with: "'")]
        }
        // Anything shorter is a word ("Mac") rather than a name.
        names = names.filter { $0.count >= 4 && $0.lowercased() != "localhost" }
            .sorted { $0.count > $1.count }
        guard !names.isEmpty else { return nil }
        return try? NSRegularExpression(
            pattern: #"(?i)(?<![\p{L}\p{N}_-])(?:"#
                + names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                + #")(?![\p{L}\p{N}_-])"#)
    }

    private static func thisMacNames() -> [String] {
        var names = [String]()
        if let name = SCDynamicStoreCopyComputerName(nil, nil) { names.append(name as String) }
        if let name = SCDynamicStoreCopyLocalHostName(nil) { names.append(name as String) }
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        if gethostname(&buffer, buffer.count - 1) == 0 { names.append(String(cString: buffer)) }
        return names
    }

    // MARK: Fixed patterns

    /// The fixed patterns are literals covered by DiagnosticsTests and
    /// DiagnosticRedactionTests, so they compile once instead of on every
    /// redaction.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// Applied before addresses: whole values whose parts could otherwise be
    /// mistaken for (or hide) an address.
    private static let fixedRules: [(NSRegularExpression, String)] = [
        (regex(#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#), "[email]"),
        (regex(#"(?<![0-9])(?:7656119[0-9]{10}|765612[0-9]{11})(?![0-9])"#), "[steamid]"),
        (regex(#"(?i)\bSTEAM_[0-5]:[01]:[0-9]+\b"#), "[steamid]"),
        (regex(#"\[U:\d:\d+\]"#), "[steamid]"),
        // Steam keeps each account's files in userdata/<account ID>.
        (regex(#"(?i)(userdata[/\\]+)\d+"#), "$1[steamid]"),
        // An environment dump: USER=ada.
        (regex(#"\b(USER|LOGNAME)=[^\s"',;\\]+"#), "$1=[user]"),
        // A Wi-Fi name may hold spaces: it runs to the closing quote, a
        // comma or the end of the line.
        (regex(#"(?i)\b(ssid\s*[:=]\s*\\?"?)[^"',;\r\n\\]+"#), "$1[wifi]"),
        (regex(#"(?i)\b[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.client\.alvr\b"#), "[headset].client.alvr"),
        (regex(#"(?i)\b[A-Z0-9][A-Z0-9-]*\.local\b"#), "[host].local"),
        (regex(#"(?i)(?<![0-9A-F:-])(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}(?![0-9A-F:-])"#), "[mac]"),
    ]

    private static let token = regex(#"(?i)\b[0-9A-F]{32,}\b"#)

    private static let ipv4 = regex(
        #"(?<![\w.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\w]|\.\d)"#)

    /// Full eight-group addresses, or compressed ones containing `::`.
    /// Shorter colon runs are left alone so timestamps never match.
    private static let ipv6 = regex(
        #"(?i)(?<![\w:])(?:(?:[0-9A-F]{1,4}:){7}[0-9A-F]{1,4}|(?:[0-9A-F]{1,4}(?::[0-9A-F]{1,4})*)?::(?:[0-9A-F]{1,4}(?::[0-9A-F]{1,4})*)?)(?:%[\w.]+)?(?![\w:])"#)

    /// A UUID, or an ADB/Quest serial: 10–20 upper-case letters and digits,
    /// both present.
    private static let uuidOrSerial = regex(
        #"(?i)\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b"#
            + "|" + #"(?-i:\b(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10,20}\b)"#)

    /// `20250101T000000`, as in a recording's file name.
    private static func isTimeStamp(_ value: String) -> Bool {
        let parts = value.split(separator: "T", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0].count == 8 && parts[1].count == 6
            && parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    private static let accountField =
        #"(?i)\b(account(?:[ _]?name)?|user[ _]?name|login|persona(?:[ _]?name)?|steam[ _]?id(?:64)?|serial(?:[ _]?number)?|computer[ _]?name|host[ _]?name)"#

    /// Identity fields take the rest of their line. For assignments, keep
    /// explicit value quotes or the next variable in an environment dump.
    private static let account = regex(accountField
        + #"([ \t]*)(?:(:[ \t]*)[^\r\n]+|(=[ \t]*)(?:(")(?:\\.|[^"\\\r\n])*""#
        + #"|(?:(?![ \t]+(?-i:[A-Z_][A-Z_0-9]*)=)[^\r\n])+))"#)

    /// Keep the enclosing string delimiters and escaped line breaks in JSON.
    private static let jsonAccountValue = #"(?:(?!\\[nr])(?:\\[\\"]|[^"\\\r\n]|\\(?!")))+"#
    private static let jsonAccount = regex(accountField
        + #"([ \t]*)(?:(:[ \t]*)"# + jsonAccountValue
        + #"|(=[ \t]*)(?:(\\")(?:(?!\5|\\[nr])[^\r\n])*\5|"# + jsonAccountValue + "))")

    static func replace(
        _ expression: NSRegularExpression, in text: String, with template: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Replaces each match with `transform(match)`, or keeps it when nil.
    private static func replaceMatches(
        _ expression: NSRegularExpression, in text: String, transform: (String) -> String?
    ) -> String {
        replaceGroup(0, of: expression, in: text, transform: transform)
    }

    /// Replaces one capture group of each match with `transform(group)`, or
    /// keeps it when nil.
    private static func replaceGroup(
        _ group: Int, of expression: NSRegularExpression, in text: String,
        transform: (String) -> String?
    ) -> String {
        var result = text
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range(at: group), in: result),
                  let replacement = transform(String(result[range])) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

extension SessionConsole {
    /// The session log as Copy and Save hand it out. The log on screen is
    /// the person's own; a copy is what gets pasted into a public issue.
    public func exportedLog(redactedWith redactor: DiagnosticRedactor) -> String {
        redactor.redact(log)
    }
}

/// A structured snapshot of the Mac, setup, bottles, profiles, stream
/// settings, recent sessions, and the session's and the game's own logs for
/// bug reports. Build it from live state, then render it with a redactor;
/// the unredacted renderings stay internal.
public struct DiagnosticReport: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let maximumLogLines = 300
    public static let maximumRecentSessions = 10

    public struct Application: Codable, Equatable, Sendable {
        public var version: String
        public var build: String?
        /// Short commit of a source checkout; nil for packaged builds.
        public var sourceRevision: String?
        public var controlProtocol: Int

        public init(version: String, build: String?, sourceRevision: String?,
                    controlProtocol: Int = Int(RuntimeLink.protocolVersion)) {
            self.version = version
            self.build = build
            self.sourceRevision = sourceRevision
            self.controlProtocol = controlProtocol
        }

        public static func current(repoRoot: URL, bundle: Bundle = .main) -> Application {
            let info = bundle.infoDictionary ?? [:]
            return Application(
                version: info["CFBundleShortVersionString"] as? String ?? "source build",
                build: info["CFBundleVersion"] as? String,
                sourceRevision: SourceRevision.read(repository: repoRoot))
        }
    }

    public struct System: Codable, Equatable, Sendable {
        public var operatingSystem: String
        public var hardwareModel: String?
        public var chip: String?
        public var architecture: String?
        public var memoryGigabytes: Int
        public var processorCount: Int
        public var thermalState: String
        public var lowPowerMode: Bool

        public init(operatingSystem: String, hardwareModel: String?, chip: String?,
                    architecture: String?, memoryGigabytes: Int, processorCount: Int,
                    thermalState: String, lowPowerMode: Bool) {
            self.operatingSystem = operatingSystem
            self.hardwareModel = hardwareModel
            self.chip = chip
            self.architecture = architecture
            self.memoryGigabytes = memoryGigabytes
            self.processorCount = processorCount
            self.thermalState = thermalState
            self.lowPowerMode = lowPowerMode
        }

        public static func current() -> System {
            let info = ProcessInfo.processInfo
            return System(
                operatingSystem: "macOS " + info.operatingSystemVersionString
                    .replacingOccurrences(of: "Version ", with: ""),
                hardwareModel: sysctlString("hw.model"),
                chip: sysctlString("machdep.cpu.brand_string"),
                architecture: sysctlString("hw.machine"),
                memoryGigabytes: Int((Double(info.physicalMemory) / 1_073_741_824).rounded()),
                processorCount: info.processorCount,
                thermalState: label(for: info.thermalState),
                lowPowerMode: info.isLowPowerModeEnabled)
        }

        static func label(for state: ProcessInfo.ThermalState) -> String {
            switch state {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
            }
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            let value = String(cString: buffer).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    public struct Check: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var status: String
        public var required: Bool
        public var detail: String
    }

    public struct Engine: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var supportsBasaltDXMT: Bool
    }

    public struct Bottle: Codable, Equatable, Sendable {
        public var name: String
        public var origin: String
        public var prefix: String
        public var engineID: String?
        public var dxmtInstalled: Bool?
        public var runtimeInstalled: Bool?
    }

    public struct Profile: Codable, Equatable, Sendable {
        public var name: String
        public var bottleName: String
        public var source: String
        public var executable: String
        public var arguments: [String]
        /// Variable names only: values may hold anything the user typed.
        public var environmentKeys: [String]
        public var hasCustomStreamSettings: Bool
    }

    public struct Session: Codable, Equatable, Sendable {
        public var state: String
        public var profileName: String?
        public var metrics: StreamMetricSummary?

        public init(state: String, profileName: String? = nil,
                    metrics: StreamMetricSummary? = nil) {
            self.state = state
            self.profileName = profileName
            self.metrics = metrics
        }
    }

    /// An excerpt of the game's own log (`GameLogExcerpt`), its personal
    /// data already replaced.
    public struct GameLog: Codable, Equatable, Sendable {
        /// The game profile it comes from; nil when no game has run.
        public var profileName: String?
        /// Empty when no log of the game was found.
        public var lines: [String]

        public init(profileName: String?, excerpt: String?) {
            self.profileName = profileName
            var lines = excerpt?.components(separatedBy: "\n") ?? []
            if lines.last?.isEmpty == true { lines.removeLast() }
            self.lines = lines
        }
    }

    public var formatVersion: Int
    public var generatedAt: Date
    public var application: Application
    public var system: System
    public var setupChecks: [Check]
    public var engines: [Engine]
    public var bottles: [Bottle]
    public var profiles: [Profile]
    public var defaultStreamSettings: StreamLaunchSettings
    public var profileStreamSettings: [String: StreamLaunchSettings]
    public var currentSession: Session
    public var recentSessions: [SessionRecord]
    /// The end of the session log, or nil when the user left it out.
    public var logTail: [String]?
    /// The game's own log, or nil when the user left it out.
    public var gameLog: GameLog?

    public init(
        generatedAt: Date = Date(),
        application: Application,
        system: System,
        setupChecks: [SetupCheck],
        engines: [BottleEngine],
        bottles: [DiscoveredBottle],
        profiles: [LaunchProfile],
        defaultStreamSettings: StreamLaunchSettings,
        profileStreamSettings: [String: StreamLaunchSettings],
        currentSession: Session,
        recentSessions: [SessionRecord],
        log: String?,
        gameLog: GameLog? = nil
    ) {
        formatVersion = Self.currentFormatVersion
        self.generatedAt = generatedAt
        self.application = application
        self.system = system
        self.setupChecks = setupChecks.map {
            Check(id: $0.id, title: $0.title, status: $0.status.rawValue,
                  required: $0.required, detail: $0.detail)
        }
        self.engines = engines.map {
            Engine(id: $0.id, kind: $0.kind.rawValue, supportsBasaltDXMT: $0.supportsBasaltDXMT)
        }
        self.bottles = bottles.map {
            Bottle(name: $0.name, origin: $0.origin.rawValue, prefix: $0.prefix.path,
                   engineID: $0.managed?.engineID,
                   dxmtInstalled: $0.managed?.dxmtInstalled,
                   runtimeInstalled: $0.managed?.runtimeInstalled)
        }
        self.profiles = profiles.map {
            Profile(name: $0.name, bottleName: $0.bottleName, source: $0.source.rawValue,
                    executable: $0.executable,
                    arguments: Self.withoutCredentials($0.arguments),
                    environmentKeys: $0.environment.keys.sorted(),
                    hasCustomStreamSettings: profileStreamSettings[$0.name] != nil)
        }
        let recentSessions = Array(recentSessions.prefix(Self.maximumRecentSessions))
        // Output device names can carry a person's name ("Ada's AirPods");
        // the report only says whether game audio goes through BlackHole.
        let audioDevices = Set(([defaultStreamSettings] + profileStreamSettings.values
                                + recentSessions.map(\.settings)).compactMap(\.audioDeviceName))
        self.defaultStreamSettings = Self.withAudioCategory(defaultStreamSettings)
        self.profileStreamSettings = profileStreamSettings.mapValues(Self.withAudioCategory)
        // The streamer's own lines are read here, as plain text: a failure
        // message becomes a table cell and a JSON string later.
        self.currentSession = currentSession
        self.currentSession.state = DiagnosticRedactor.redactStreamerLines(in: currentSession.state)
        self.recentSessions = recentSessions.map {
            var record = $0
            record.settings = Self.withAudioCategory(record.settings)
            record.failureReason = record.failureReason.map(DiagnosticRedactor.redactStreamerLines)
            return record
        }
        logTail = log.map { log in
            Self.tail(of: DiagnosticRedactor.redactStreamerLines(
                in: audioDevices.sorted { $0.count > $1.count }.reduce(log) {
                    $1.isEmpty ? $0 : $0.replacingOccurrences(of: $1, with: Self.audioCategory($1))
                }))
        }
        self.gameLog = gameLog.map {
            GameLog(profileName: $0.profileName,
                    excerpt: DiagnosticRedactor.redactStreamerLines(in: $0.lines.joined(separator: "\n")))
        }
    }

    /// A launch argument may be an account name or a password
    /// (`-login name password`): what follows such a flag is left out.
    static func withoutCredentials(_ arguments: [String]) -> [String] {
        let flags: Set = ["login", "user", "username", "account", "password", "pass", "token"]
        var afterFlag = false
        return arguments.map { argument in
            guard argument.hasPrefix("-") || argument.hasPrefix("+") else {
                return afterFlag ? "[redacted]" : argument
            }
            let parts = argument.drop { $0 == "-" || $0 == "+" }
                .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let isCredential = parts.first.map { flags.contains($0.lowercased()) } ?? false
            afterFlag = isCredential && parts.count == 1
            guard isCredential, parts.count == 2 else { return argument }
            return argument.prefix { $0 != "=" } + "=[redacted]"
        }
    }

    static func audioCategory(_ deviceName: String) -> String {
        deviceName.localizedCaseInsensitiveContains("BlackHole") ? "BlackHole" : "[audio device]"
    }

    private static func withAudioCategory(_ settings: StreamLaunchSettings) -> StreamLaunchSettings {
        var settings = settings
        settings.audioDeviceName = settings.audioDeviceName.map(audioCategory)
        return settings
    }

    /// Pretty-printed JSON with every string passed through `redactor`.
    public func json(redactedWith redactor: DiagnosticRedactor) throws -> String {
        redactor.redactIdentifiers(in: try renderJSON(), preservingJSON: true)
    }

    /// GitHub-flavored Markdown, ready to paste into an issue, with every
    /// string passed through `redactor`.
    public func markdown(redactedWith redactor: DiagnosticRedactor) -> String {
        redactor.redactIdentifiers(in: renderMarkdown())
    }

    func renderJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    func renderMarkdown() -> String {
        let dates = ISO8601DateFormatter()
        var lines = [String]()

        lines += [
            "## BasaltVR diagnostic report", "",
            "Generated \(dates.string(from: generatedAt)) · report format \(formatVersion)", "",
            "| | |", "|---|---|",
            row("BasaltVR", [
                application.version,
                application.build.map { "build \($0)" },
                application.sourceRevision.map { "commit \($0)" },
                "control protocol v\(application.controlProtocol)",
            ]),
            row("macOS", [system.operatingSystem]),
            row("Mac", [
                system.hardwareModel, system.chip, system.architecture,
                "\(system.memoryGigabytes) GB", "\(system.processorCount) cores",
            ]),
            row("Power", [
                "thermal \(system.thermalState)",
                "Low Power Mode \(system.lowPowerMode ? "on" : "off")",
            ]),
        ]

        lines += ["", "### Setup", ""]
        lines += setupChecks.isEmpty ? ["No setup checks have run."] : setupChecks.map {
            "- [\($0.status == SetupCheckStatus.ready.rawValue ? "x" : " ")] "
                + "**\($0.title)**\($0.required ? "" : " (optional)") — \(flat($0.detail))"
        }

        lines += ["", "### Wine engines", ""]
        lines += engines.isEmpty ? ["None found."] : engines.map {
            "- `\($0.id)` (\($0.kind)\($0.supportsBasaltDXMT ? ", Basalt DXMT" : ""))"
        }

        lines += ["", "### Bottles", ""]
        if bottles.isEmpty {
            lines.append("None found.")
        } else {
            lines += ["| Bottle | Origin | Engine | DXMT | Runtime |", "|---|---|---|---|---|"]
            lines += bottles.map {
                "| \(cell($0.name)) | \($0.origin) | \(cell($0.engineID ?? "—")) "
                    + "| \(mark($0.dxmtInstalled)) | \(mark($0.runtimeInstalled)) |"
            }
        }

        lines += ["", "### Launch profiles", ""]
        if profiles.isEmpty {
            lines.append("None.")
        } else {
            lines += ["| Profile | Bottle | Source | Executable | Stream settings |",
                      "|---|---|---|---|---|"]
            lines += profiles.map {
                let arguments = $0.arguments.isEmpty ? "" : " " + $0.arguments.joined(separator: " ")
                return "| \(cell($0.name)) | \(cell($0.bottleName)) | \($0.source) "
                    + "| \(cell($0.executable + arguments)) "
                    + "| \($0.hasCustomStreamSettings ? "custom" : "default") |"
            }
        }

        lines += ["", "### Stream settings", "",
                  "- Default: \(Self.describe(defaultStreamSettings))"]
        lines += profileStreamSettings.sorted { $0.key < $1.key }.map {
            "- \($0.key): \(Self.describe($0.value))"
        }

        lines += ["", "### Current session", "", "- State: \(flat(currentSession.state))"]
        if let profile = currentSession.profileName { lines.append("- Profile: \(profile)") }
        if let metrics = currentSession.metrics, !metrics.isEmpty {
            lines.append("- Metrics: \(Self.describe(metrics))")
        }

        lines += ["", "### Recent sessions", ""]
        if recentSessions.isEmpty {
            lines.append("None recorded.")
        } else {
            lines += ["| Started | Profile | Settings | Streamed | Outcome | Metrics |",
                      "|---|---|---|---|---|---|"]
            lines += recentSessions.map { record in
                let outcome = record.outcome.map {
                    $0 == .failed ? "failed: \(record.failureReason ?? "unknown")" : $0.rawValue
                } ?? "unfinished"
                return "| \(dates.string(from: record.startedAt)) | \(cell(record.profileName)) "
                    + "| \(cell(Self.describe(record.settings))) "
                    + "| \(record.streamingDuration.map(Self.describe(duration:)) ?? "—") "
                    + "| \(cell(outcome)) | \(cell(Self.describe(record.metrics))) |"
            }
        }

        // Each with the session it belongs to.
        lines += ["", "### Hints", ""]
        let hints = recentSessions.flatMap { record in
            (record.hints ?? []).map {
                "- \(dates.string(from: record.startedAt)) · \(flat(record.profileName)): \(flat($0))"
            }
        }
        lines += hints.isEmpty ? ["None."] : hints

        lines += ["", "### Session log", ""]
        if let logTail, !logTail.isEmpty {
            let fence = Self.fence(for: logTail)
            lines += ["<details><summary>Last \(logTail.count) lines</summary>", "",
                      fence + "text"]
            lines += logTail
            lines += [fence, "", "</details>"]
        } else {
            lines.append(logTail == nil ? "Not included." : "Empty.")
        }

        lines += ["", "### Game log", ""]
        if let gameLog, !gameLog.lines.isEmpty {
            let fence = Self.fence(for: gameLog.lines)
            let source = gameLog.profileName.map { " from \($0)" } ?? ""
            lines += ["<details><summary>Excerpt\(source): \(gameLog.lines.count) lines</summary>", "",
                      fence + "text"]
            lines += gameLog.lines
            lines += [fence, "", "</details>"]
        } else {
            lines.append(gameLog == nil ? "Not included." : "No log of the game was found.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Formatting

    static func describe(_ settings: StreamLaunchSettings) -> String {
        var parts = [
            settings.connection.label, "\(settings.fps) fps", "\(settings.megabits) Mbps",
            settings.resolution.label, "\(settings.latency.rawValue) latency",
        ]
        switch settings.gameAudioChoice {
        case .mac: parts.append("audio Mac output")
        case .device(let name): parts.append("audio \(name)")
        case .off: parts.append("no game audio")
        }
        if settings.gamePriorityHigh { parts.append("high game priority") }
        return parts.joined(separator: " · ")
    }

    static func describe(_ metrics: StreamMetricSummary) -> String {
        guard !metrics.isEmpty else { return "no reports" }
        var parts = [String]()
        if let average = metrics.fps.average, let low = metrics.fps.minimum {
            parts.append(String(format: "%.1f fps avg (min %.1f)", average, low))
        }
        if let share = metrics.lowFrameRateShare, share > 0 {
            parts.append(String(format: "%.0f%% below target", share * 100))
        }
        if let average = metrics.latencyMilliseconds.average,
           let high = metrics.latencyMilliseconds.maximum {
            parts.append(String(format: "%.0f ms avg (max %.0f)", average, high))
        }
        if let average = metrics.megabits.average {
            parts.append(String(format: "%.1f Mbps avg", average))
        }
        return parts.joined(separator: ", ")
    }

    static func describe(duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min \(seconds % 60) s" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }

    /// The last `maximumLogLines` lines without terminal color codes.
    static func tail(of log: String) -> [String] {
        let plain = log.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        var lines = plain.components(separatedBy: .newlines)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return Array(lines.suffix(maximumLogLines))
    }

    /// A backtick fence longer than any backtick run in the content.
    static func fence(for lines: [String]) -> String {
        var longest = 0
        for line in lines {
            var run = 0
            for character in line {
                run = character == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    private func row(_ title: String, _ values: [String?]) -> String {
        "| \(title) | \(cell(values.compactMap { $0 }.joined(separator: " · "))) |"
    }

    private func cell(_ value: String) -> String {
        flat(value).replacingOccurrences(of: "|", with: "\\|")
    }

    private func flat(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }

    private func mark(_ value: Bool?) -> String {
        value.map { $0 ? "yes" : "no" } ?? "—"
    }
}

/// Reads the checked-out commit of a source tree without running git.
public enum SourceRevision {
    public static func read(repository: URL, length: Int = 12) -> String? {
        guard let gitDirectory = gitDirectory(in: repository),
              let head = contents(of: gitDirectory.appendingPathComponent("HEAD"))
        else { return nil }
        let sha: String?
        if head.hasPrefix("ref:") {
            let reference = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let common = commonDirectory(for: gitDirectory)
            sha = [gitDirectory, common].lazy.compactMap {
                contents(of: $0.appendingPathComponent(reference))
            }.first ?? packedReference(reference, in: common)
        } else {
            sha = head
        }
        guard let sha, isObjectName(sha) else { return nil }
        return String(sha.prefix(length))
    }

    /// `.git` is a directory in a normal checkout and a `gitdir:` file in a
    /// worktree or submodule.
    private static func gitDirectory(in repository: URL) -> URL? {
        let dotGit = repository.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory)
        else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let link = contents(of: dotGit), link.hasPrefix("gitdir:") else { return nil }
        return resolve(link.dropFirst(7).trimmingCharacters(in: .whitespaces), against: repository)
    }

    private static func commonDirectory(for gitDirectory: URL) -> URL {
        guard let path = contents(of: gitDirectory.appendingPathComponent("commondir"))
        else { return gitDirectory }
        return resolve(path, against: gitDirectory)
    }

    private static func resolve(_ path: String, against directory: URL) -> URL {
        (path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : directory.appendingPathComponent(path, isDirectory: true)).standardizedFileURL
    }

    private static func packedReference(_ reference: String, in gitDirectory: URL) -> String? {
        guard let packed = contents(of: gitDirectory.appendingPathComponent("packed-refs"))
        else { return nil }
        for line in packed.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            if fields.count == 2, fields[1] == reference { return String(fields[0]) }
        }
        return nil
    }

    private static func contents(of file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isObjectName(_ value: String) -> Bool {
        (40...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
}
