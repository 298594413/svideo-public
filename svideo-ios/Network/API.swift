import Foundation
import CryptoKit

/// 快猫 svideo 协议层
/// - 域名轮换: 4个备用域名，逐个探测可用的
/// - 签名: sig = MD5(按key排序的"&k=v(urlEncode)"拼接串 + "maomi_pass_xyz")
/// - AES: AES/ECB/NoPadding, key=625202f9149maomi (部分场景用)
final class API {
    static let shared = API()

    // Constants（从 smali com.mylibrary.Constant 提取）
    let domains = [
        "api.kkmmapi.com",
        "api.ppmapi.com",
        "888.apikm.com",
        "999.km58888.com",
    ]
    let sigKey = "maomi_pass_xyz"
    let aesPwd = "625202f9149maomi"
    let aesIv  = "5efd3f6060emaomi"

    /// 统一读取当前用户 uId（String/Int 双兼容已写入）
    var currentUid: String {
        UserDefaults.standard.string(forKey: "mu_id") ?? ""
    }

    /// 当前可用域名（探测后缓存）
    private(set) var currentDomain: String?
    /// 登录 token（持久化到 UserDefaults，重启保持登录）
    var token: String? {
        didSet {
            if let t = token { UserDefaults.standard.set(t, forKey: "mu_token") }
            else { UserDefaults.standard.removeObject(forKey: "mu_token") }
        }
    }
    init() {
        self.token = UserDefaults.standard.string(forKey: "mu_token")
    }

    // MARK: - 签名
    /// 参数签名：TreeMap 排序 → "k=v&k=v"（value 做 urlEncode）→ MD5(sig串 + key)
    func sign(_ params: [String: String]) -> String {
        let sorted = params.sorted { $0.key < $1.key }
        let joined = sorted.map { k, v in
            let enc = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(k)=\(enc)"
        }.joined(separator: "&")
        let raw = joined + sigKey
        return md5(raw)
    }

    private func md5(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 域名探测
    /// 入口地址（从 APK 抓包提取）：先试 getSiteName 下发的域名，再试 smali 域名，再试抓包入口IP
    func detectDomain() async -> String? {
        if let d = currentDomain { return d }
        // 候选：(host, scheme, 是否需要端口)
        let candidates: [(String, String)] = [
            ("api.cheetah888.com", "https"),
            ("api.mercenary123.com", "https"),
            ("api.hawkeyegogo.com", "https"),
            ("api.disco8080.com", "https"),
            ("18.167.17.100:8099", "http"),   // 抓包时的实际入口
            ("api.kkmmapi.com", "https"),
            ("api.ppmapi.com", "https"),
            ("888.apikm.com", "https"),
            ("999.km58888.com", "https"),
        ]
        for (host, scheme) in candidates {
            if await testDomain(host, scheme) {
                currentDomain = "\(scheme)://\(host)"
                return currentDomain
            }
        }
        return nil
    }

    /// 探测入口：调 getSiteName，能 AES 解密出域名列表即视为可用
    private func testDomain(_ host: String, _ scheme: String) async -> Bool {
        guard let url = URL(string: "\(scheme)://\(host)/api/system/getSiteName") else { return false }
        var all = deviceParams
        all["data"] = aesEncryptHex("{\"type\":\"1\"}")   // 抓包 getSiteName 的 data
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = signedBody(all).data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            // 响应是 AES 密文 HEX，解密后应含域名列表
            if let text = String(data: data, encoding: .utf8),
               let plain = aesDecryptHex(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               plain.contains("api.") { return true }
            return false
        } catch { return false }
    }

    // MARK: - 请求体构造
    func signedBody(_ params: [String: String]) -> String {
        var p = params
        p["sig"] = sign(params)
        return p.map { k, v in
            let enc = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(k)=\(enc)"
        }.joined(separator: "&")
    }

    /// 设备参数（参与签名）—— 从 APK 抓包提取
    var deviceParams: [String: String] {
        [
            "_app_version": "1.0.4",
            "_device_id": deviceId,
            "_device_type": "1801-A01",
            "_device_version": "7.1.1",
            "_sdk_version": "25",
        ]
    }
    var deviceId: String {
        // 固定一个设备ID（真机抓包是 866700032808626）—— 用稳定的字符串避免风控
        if let saved = UserDefaults.standard.string(forKey: "device_id") { return saved }
        let id = "866" + String(format: "%012d", Int.random(in: 0...999_999_999_999))
        UserDefaults.standard.set(id, forKey: "device_id")
        return id
    }

    // MARK: - 通用请求（带设备参数 + 响应解密）
    func call(_ path: String, params: [String: String] = [:]) async -> [String: Any]? {
        guard let base = await detectDomain(),
              let url = URL(string: "\(base)\(path)") else { return nil }
        var all = deviceParams
        all.merge(params) { _, new in new }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let tok = token { req.setValue(tok, forHTTPHeaderField: "Authorization") }
        req.httpBody = signedBody(all).data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return parseResponse(data)
        } catch { return nil }
    }

    /// 解析响应：可能是明文 JSON，也可能是 AES 加密的大写HEX
    private func parseResponse(_ data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // 先看是否 JSON
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        // 否则当 AES-HEX 解密
        if let plain = aesDecryptHex(text),
           let pdata = plain.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] { return obj }
        return nil
    }

    /// AES-CBC 解密 → 明文字符串（去PKCS7 padding）
    func aesDecryptHex(_ hex: String) -> String? {
        guard let ct = hexToBytes(hex), ct.count % 16 == 0 else { return nil }
        let key = Array(padded16(aesPwd))
        let iv  = Array(padded16(aesIv))
        var out = [UInt8]()
        var prev = iv
        var block = [UInt8](repeating: 0, count: 16)
        for i in stride(from: 0, to: ct.count, by: 16) {
            for j in 0..<16 { block[j] = ct[i+j] }
            let dec = aesDecryptBlock(block, key: key)
            for j in 0..<16 { out.append(dec[j] ^ prev[j]) }
            prev = block
        }
        guard let pad = out.last, pad > 0, pad <= 16 else { return nil }
        return String(bytes: out.dropLast(Int(pad)), encoding: .utf8)
    }

    private func hexToBytes(_ hex: String) -> [UInt8]? {
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    // MARK: - AES-CBC 加密（登录等接口用）
    /// 对应 AesEncryptionUtil.encrypt: AES/CBC/PKCS5Padding(key/iv UTF8补齐16字节) → 大写HEX
    func aesEncryptHex(_ json: String) -> String {
        let key = Array(padded16(aesPwd))
        let iv  = Array(padded16(aesIv))
        let data = Array(json.utf8)
        // PKCS7 padding (块大小16)
        let pad = 16 - (data.count % 16)
        let padded = data + Array(repeating: UInt8(pad), count: pad)
        var out = [UInt8]()
        var prev = iv
        var block = [UInt8](repeating: 0, count: 16)
        for i in stride(from: 0, to: padded.count, by: 16) {
            for j in 0..<16 { block[j] = padded[i+j] ^ prev[j] }
            let enc = aesEncryptBlock(block, key: key)
            out.append(contentsOf: enc)
            prev = enc
        }
        return out.map { String(format: "%02X", $0) }.joined()
    }

    private func padded16(_ s: String) -> [UInt8] {
        var b = Array(s.utf8)
        if b.count < 16 { b += Array(repeating: 0, count: 16 - b.count) }
        return Array(b.prefix(16))
    }

    /// 单块 AES-128 加密（标准实现）
    private func aesEncryptBlock(_ input: [UInt8], key: [UInt8]) -> [UInt8] {
        let rounds = 10
        var w = [[UInt8]](repeating: [UInt8](repeating: 0, count: 4), count: 4*11)
        for i in 0..<4 { w[i] = [key[4*i], key[4*i+1], key[4*i+2], key[4*i+3]] }
        let sbox: [UInt8] = [
          0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
          0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
          0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
          0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
          0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
          0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
          0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
          0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
          0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
          0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
          0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
          0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
          0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
          0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
          0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
          0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16]
        func xt(_ a: UInt8) -> UInt8 { return (a & 0x80 != 0) ? ((a << 1) ^ 0x1b) : (a << 1) }
        let rcon: [UInt8] = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36]
        for i in 4..<(4*(rounds+1)) {
            var t = w[i-1]
            if i % 4 == 0 {
                t = [sbox[Int(t[1])] ^ rcon[i/4-1], sbox[Int(t[2])], sbox[Int(t[3])], sbox[Int(t[0])]]
            }
            for j in 0..<4 { w[i][j] = w[i-4][j] ^ t[j] }
        }
        var s = input
        func addRoundKey(_ r: Int) { for j in 0..<16 { s[j] ^= w[r*4 + j/4][j%4] } }
        addRoundKey(0)
        for r in 1..<rounds {
            s = s.map { sbox[Int($0)] }
            // ShiftRows
            let tmp = s
            for row in 1..<4 { for col in 0..<4 { s[4*col+row] = tmp[4*((col+row)%4)+row] } }
            // MixColumns
            for c in 0..<4 {
                let a0=s[4*c],a1=s[4*c+1],a2=s[4*c+2],a3=s[4*c+3]
                let all=a0^a1^a2^a3
                s[4*c]   = a0 ^ all ^ xt(a0^a1)
                s[4*c+1] = a1 ^ all ^ xt(a1^a2)
                s[4*c+2] = a2 ^ all ^ xt(a2^a3)
                s[4*c+3] = a3 ^ all ^ xt(a3^a0)
            }
            addRoundKey(r)
        }
        s = s.map { sbox[Int($0)] }
        let tmp = s
        for row in 1..<4 { for col in 0..<4 { s[4*col+row] = tmp[4*((col+row)%4)+row] } }
        addRoundKey(rounds)
        return s
    }

    /// 单块 AES-128 解密（aesEncryptBlock 的逆运算）
    private func aesDecryptBlock(_ input: [UInt8], key: [UInt8]) -> [UInt8] {
        let rounds = 10
        // 复用加密的 key expansion（同样的 w）
        var w = [[UInt8]](repeating: [UInt8](repeating: 0, count: 4), count: 4*11)
        for i in 0..<4 { w[i] = [key[4*i], key[4*i+1], key[4*i+2], key[4*i+3]] }
        let sbox: [UInt8] = [
          0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
          0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
          0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
          0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
          0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
          0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
          0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
          0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
          0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
          0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
          0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
          0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
          0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
          0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
          0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
          0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16]
        let invSbox: [UInt8] = {
            var inv = [UInt8](repeating: 0, count: 256)
            for (i, v) in sbox.enumerated() { inv[Int(v)] = UInt8(i) }
            return inv
        }()
        func xt(_ a: UInt8) -> UInt8 { return (a & 0x80 != 0) ? ((a << 1) ^ 0x1b) : (a << 1) }
        func gmul(_ a: UInt8, _ b: UInt8) -> UInt8 {
            var r: UInt8 = 0; var x = a; var y = b
            while y != 0 { if y & 1 != 0 { r ^= x }; x = xt(x); y >>= 1 }
            return r
        }
        let rcon: [UInt8] = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36]
        for i in 4..<(4*(rounds+1)) {
            var t = w[i-1]
            if i % 4 == 0 {
                t = [sbox[Int(t[1])] ^ rcon[i/4-1], sbox[Int(t[2])], sbox[Int(t[3])], sbox[Int(t[0])]]
            }
            for j in 0..<4 { w[i][j] = w[i-4][j] ^ t[j] }
        }
        var s = input
        func addRoundKey(_ r: Int) { for j in 0..<16 { s[j] ^= w[r*4 + j/4][j%4] } }
        addRoundKey(rounds)
        for r in (1..<rounds).reversed() {
            // InvShiftRows
            let tmp = s
            for row in 1..<4 { for col in 0..<4 { s[4*((col+row)%4)+row] = tmp[4*col+row] } }
            // InvSubBytes
            s = s.map { invSbox[Int($0)] }
            addRoundKey(r)
            // InvMixColumns
            for c in 0..<4 {
                let a0=s[4*c],a1=s[4*c+1],a2=s[4*c+2],a3=s[4*c+3]
                s[4*c]   = gmul(a0,14)^gmul(a1,11)^gmul(a2,13)^gmul(a3,9)
                s[4*c+1] = gmul(a0,9)^gmul(a1,14)^gmul(a2,11)^gmul(a3,13)
                s[4*c+2] = gmul(a0,13)^gmul(a1,9)^gmul(a2,14)^gmul(a3,11)
                s[4*c+3] = gmul(a0,11)^gmul(a1,13)^gmul(a2,9)^gmul(a3,14)
            }
        }
        let tmp = s
        for row in 1..<4 { for col in 0..<4 { s[4*((col+row)%4)+row] = tmp[4*col+row] } }
        s = s.map { invSbox[Int($0)] }
        addRoundKey(0)
        return s
    }

    // MARK: - 业务接口
    /// 登录：JSON{email,password} → AES加密成大写HEX → POST form "data=<hex>" + sig
    func login(phone: String, password: String) async -> [String: Any]? {
        let json = "{\"email\":\"\(phone)\",\"password\":\"\(password)\"}"
        let enc = aesEncryptHex(json)
        let r = await call("/api/users/login", params: ["data": enc])
        // token 字段：抓包确认是 mu_token；同时保存 mu_id（评论/收藏用）
        if let d = r?["data"] as? [String: Any] {
            for k in ["mu_token", "token", "accessToken", "uToken", "sessionId"] {
                if let t = d[k] as? String { token = t; break }
            }
            // mu_id 兼容 String/Int（服务端两种都可能）
            if let uid = d["mu_id"] as? String {
                UserDefaults.standard.set(uid, forKey: "mu_id")
            } else if let uid = d["mu_id"] as? Int {
                UserDefaults.standard.set(String(uid), forKey: "mu_id")
            }
        }
        return r
    }

    // MARK: - 社区接口（参数名实测探明：mvId/uId）
    func comments(mvId: String, page: Int = 1) async -> [[String: Any]]? {
        let enc = aesEncryptHex("{\"mvId\":\"\(mvId)\",\"page\":\(page),\"perPage\":20}")
        let r = await call("/api/community/listComments", params: ["data": enc])
        guard let data = r?["data"] else { return nil }
        if let arr = data as? [[String: Any]] { return arr }
        if let dict = data as? [String: Any], let list = dict["list"] as? [[String: Any]] { return list }
        return nil
    }

    func addComment(mvId: String, content: String) async -> [String: Any]? {
        let uid = currentUid
        // 抓包确认字段名 mcText
        let enc = aesEncryptHex("{\"uId\":\"\(uid)\",\"mvId\":\"\(mvId)\",\"mcText\":\"\(content)\"}")
        return await call("/api/community/addComment", params: ["data": enc])
    }

    func likeVideo(mvId: String) async -> [String: Any]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"uId\":\"\(uid)\",\"mvId\":\"\(mvId)\"}")
        return await call("/api/community/videoLike", params: ["data": enc])
    }

    func collectVideo(mvId: String) async -> [String: Any]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"uId\":\"\(uid)\",\"mvId\":\"\(mvId)\"}")
        return await call("/api/community/videoCollect", params: ["data": enc])
    }

    func collectList(page: Int = 1) async -> [[String: Any]]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"uId\":\"\(uid)\",\"page\":\(page),\"perPage\":14}")
        let r = await call("/api/community/videoCollectList", params: ["data": enc])
        guard let data = r?["data"] else { return nil }
        var list: [[String: Any]] = []
        if let arr = data as? [[String: Any]] { list = arr }
        else if let dict = data as? [String: Any], let l = dict["list"] as? [[String: Any]] { list = l }
        // 收藏列表结构：{vc_id, mv_id, video:{mv_title,mv_img_url,mv_editor...}}
        // 平铺 video 子对象，让 VideoItem 直接读
        return list.map { item -> [String: Any] in
            var v = item
            if let video = item["video"] as? [String: Any] {
                for (k, val) in video { v[k] = val }
            }
            return v
        }
    }

    /// 关注列表（实测需 uId，返回关注的用户数组）
    func attentionListUsers() async -> [[String: Any]]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"uId\":\"\(uid)\"}")
        let r = await call("/api/community/attentionList", params: ["data": enc])
        guard let data = r?["data"] else { return nil }
        if let arr = data as? [[String: Any]] { return arr }
        if let dict = data as? [String: Any], let list = dict["list"] as? [[String: Any]] { return list }
        return nil
    }

    /// 关注用户（实测参数 attentionId + uId，带token）
    func followUser(attentionId: String) async -> [String: Any]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"attentionId\":\"\(attentionId)\",\"uId\":\"\(uid)\"}")
        return await call("/api/community/attentionUser", params: ["data": enc])
    }

    /// 与某用户的私信记录
    func oneChats(otherUid: String) async -> [[String: Any]]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"uId\":\"\(uid)\",\"otherUid\":\"\(otherUid)\"}")
        let r = await call("/api/chats/listOneChats", params: ["data": enc])
        guard let data = r?["data"] else { return nil }
        if let dict = data as? [String: Any], let list = dict["list"] as? [[String: Any]] { return list }
        if let arr = data as? [[String: Any]] { return arr }
        return nil
    }

    /// 发私信
    func sendMsg(toUid: String, content: String) async -> [String: Any]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"uId\":\"\(uid)\",\"toUid\":\"\(toUid)\",\"content\":\"\(content)\"}")
        return await call("/api/chats/sendMsg", params: ["data": enc])
    }

    /// 私信用户列表
    func chatUsers() async -> [[String: Any]]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"uId\":\"\(uid)\"}")
        let r = await call("/api/chats/getChatUsers", params: ["data": enc])
        guard let data = r?["data"] else { return nil }
        if let dict = data as? [String: Any], let list = dict["list"] as? [[String: Any]] { return list }
        if let arr = data as? [[String: Any]] { return arr }
        return nil
    }

    /// 用户信息（登录后显示资料）—— 抓包确认用 userdata + uId
    func userInfo() async -> [String: Any]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"uId\":\"\(uid)\"}")
        let r = await call("/api/users/userdata", params: ["data": enc])
        return r?["data"] as? [String: Any]
    }

    // MARK: - 视频列表（热门/广场）
    // 抓包确认：data={"page":N,"perPage":14,"uId":登录ID}
    // 热门=listHot（最新1-2天），广场=listAll（可翻页看历史）
    private func videoListRequest(_ path: String, page: Int, perPage: Int = 14) async -> [[String: Any]]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"page\":\(page),\"perPage\":\(perPage),\"uId\":\"\(uid)\"}")
        let r = await call(path, params: ["data": enc])
        guard let data = r?["data"] else { return nil }
        if let arr = data as? [[String: Any]] { return arr }
        if let dict = data as? [String: Any], let list = dict["list"] as? [[String: Any]] { return list }
        return nil
    }

    /// 热门（最新内容）
    func videoList(page: Int = 1) async -> [[String: Any]]? {
        return await videoListRequest("/api/videos/listHot", page: page)
    }

    /// 广场（可翻页历史）
    func squareList(page: Int = 1) async -> [[String: Any]]? {
        return await videoListRequest("/api/videos/listAll", page: page)
    }

    /// 视频详情：服务端直接返回替换好CDN域名的播放地址 + 收藏/关注状态
    func videoDetail(mvId: String) async -> [String: Any]? {
        let uid = currentUid
        let enc = aesEncryptHex("{\"uId\":\"\(uid)\",\"mvId\":\"\(mvId)\",\"type\":\"2\"}")
        let r = await call("/api/videos/detail", params: ["data": enc])
        return r?["data"] as? [String: Any]
    }
}
