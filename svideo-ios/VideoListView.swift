import SwiftUI
import AVKit

/// 缓存管理：播放过的视频后台下载到 Documents/VideoCache/
final class CacheStore: ObservableObject {
    static let shared = CacheStore()
    @Published var files: [URL] = []

    let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let p = d.appendingPathComponent("VideoCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p
    }()

    init() { refresh() }

    func refresh() {
        files = (try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]))?
            .filter { ["mp4","m4v","mov"].contains($0.pathExtension.lowercased()) } ?? []
    }

    /// 缓存文件名：作者昵称_视频标题.mp4（非法字符替换）
    func localURL(id: String, author: String, title: String) -> URL {
        var name = "\(author)_\(title)"
        // 去掉文件系统非法字符
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        name = name.components(separatedBy: bad).joined(separator: "_")
        if name.count > 80 { name = String(name.prefix(80)) }
        return dir.appendingPathComponent("\(name)_\(id.suffix(6)).mp4")
    }
    /// 按 id 后缀查找已缓存文件（文件名以 _id后6位.mp4 结尾）
    func cachedURL(for id: String) -> URL? {
        let suffix = "_\(id.suffix(6)).mp4"
        return files.first { $0.lastPathComponent.hasSuffix(suffix) }
    }

    /// 后台缓存视频（文件名：作者_标题_id.mp4）
    func cacheVideo(remote: URL, id: String, author: String, title: String) {
        let local = localURL(id: id, author: author, title: title)
        guard !FileManager.default.fileExists(atPath: local.path) else { return }
        URLSession.shared.downloadTask(with: remote) { tmp, _, err in
            guard let tmp = tmp, err == nil else { return }
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.moveItem(at: tmp, to: local)
            DispatchQueue.main.async { self.refresh() }
        }.resume()
    }

    func sizeText(for id: String) -> String? {
        guard let u = cachedURL(for: id),
              let a = try? FileManager.default.attributesOfItem(atPath: u.path),
              let n = a[.size] as? NSNumber else { return nil }
        return n.int64Value > 1024*1024
            ? String(format: "%.1fMB", Double(n.int64Value)/1024/1024)
            : "\(n.int64Value/1024)KB"
    }
}

/// 视频数据模型
struct VideoItem: Identifiable {
    let id: String
    let title: String
    let author: String
    let authorUid: String
    let coverURL: String?
    let playURL: String?
    let likes: Int
    let raw: [String: Any]

    init(_ v: [String: Any]) {
        if let s = v["mv_id"] as? String { id = s }
        else if let n = v["mv_id"] as? Int { id = String(n) }
        else { id = UUID().uuidString }
        title = v["mv_title"] as? String ?? "视频"
        author = v["mu_name"] as? String ?? v["mv_editor"] as? String ?? "未知"
        authorUid = v["mu_id"] as? String ?? (v["mu_id"] as? Int).map(String.init) ?? ""
        coverURL = v["mv_img_url"] as? String
        // 播放地址：列表返回的是老IP；真实CDN地址点进详情时由 detail 接口返回
        playURL = v["mv_play_url"] as? String ?? v["url"] as? String
        // 服务端数值全是字符串（"1357"），安全转换
        if let n = v["mv_like"] as? Int { likes = n }
        else if let s = v["mv_like"] as? String { likes = Int(s) ?? 0 }
        else if let d = v["mv_like"] as? Double { likes = Int(d) }
        else { likes = 0 }
        raw = v
    }
}

/// 评论模型（修复昵称与内容错位：按唯一ID绑定行）
struct CommentItem: Identifiable {
    let id: String
    let user: String
    let content: String
    let date: String

    init(_ c: [String: Any], index: Int) {
        if let s = c["cm_id"] as? String { id = s }
        else if let n = c["cm_id"] as? Int { id = String(n) }
        else { id = "c\(index)_\(c["cm_created"] as? String ?? "")" }
        user = c["mu_name"] as? String ?? "用户"
        content = c["mc_text"] as? String ?? ""   // 实测字段名 mc_text
        date = c["mc_created"] as? String ?? ""
    }
}

/// 首页：热门/广场/关注 三个Tab（参考 APK 主页）+ 封面网格
struct VideoFeedView: View {
    @ObservedObject private var cache = CacheStore.shared
    @State private var tab = 0          // 0=热门 1=广场 2=关注
    @State private var hotVideos: [VideoItem] = []
    @State private var squareVideos: [VideoItem] = []
    @State private var attentionUsers: [[String: Any]] = []
    @State private var showLogin = false
    @State private var loggedIn = false
    @State private var loading = false
    @State private var loadError = ""
    @State private var selected: VideoItem?
    @State private var detail: [String: Any]?
    @State private var loadingMore = false
    @State private var squarePage = 1
    @State private var squareEnd = false

    private let cols = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部Tab条
                HStack(spacing: 24) {
                    ForEach(0..<3) { i in
                        Button {
                            tab = i
                            load()
                        } label: {
                            Text(["热门","广场","关注"][i])
                                .font(.system(size: 16, weight: tab == i ? .bold : .regular))
                                .foregroundColor(tab == i ? .pink : .gray)
                        }
                    }
                    Spacer()
                    Button { showLogin = true } label: {
                        Image(systemName: loggedIn ? "person.circle.fill" : "person.circle")
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)

                Divider()

                // 内容区
                ZStack {
                    Color.white
                    if loading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("加载中...").font(.caption).foregroundColor(.gray)
                        }
                    } else if currentList.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "video.slash").font(.largeTitle).foregroundColor(.gray)
                            Text(loadError.isEmpty ? "暂无内容" : loadError).font(.subheadline).foregroundColor(.gray)
                            Button("重试") { load() }
                        }
                    } else if tab == 2 {
                        // 关注Tab：用户列表（attentionList 返回关注的用户）
                        List {
                            ForEach(Array(attentionUsers.enumerated()), id: \.offset) { _, u in
                                HStack(spacing: 10) {
                                    AsyncImage(url: (u["mu_avatar"] as? String).flatMap(URL.init)) { ph in
                                        if case .success(let img) = ph {
                                            img.resizable().scaledToFill()
                                        } else {
                                            Image(systemName: "person.circle.fill")
                                                .resizable().scaledToFit().foregroundColor(.gray)
                                        }
                                    }
                                    .frame(width: 44, height: 44).clipped().cornerRadius(22)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(u["mu_name"] as? String ?? "用户").font(.subheadline).bold()
                                        Text("粉丝 \(u["mu_attention_me_count"] as? String ?? "0") · \(u["levelName"] as? String ?? "")")
                                            .font(.caption).foregroundColor(.gray)
                                    }
                                    Spacer()
                                    Text("已关注").font(.caption).foregroundColor(.gray)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listStyle(.plain)
                } else {
                        ScrollView {
                            LazyVGrid(columns: cols, spacing: 2) {
                                ForEach(currentList) { v in
                                    VideoGridCell(v: v, cache: cache)
                                        .onTapGesture { tapVideo(v) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 2)
                            // 广场滚到底自动加载下一页（onAppear + 手动按钮双保险）
                            if tab == 1 && !squareVideos.isEmpty {
                                VStack(spacing: 8) {
                                    if loadingMore {
                                        HStack(spacing: 8) {
                                            ProgressView()
                                            Text("加载中...").font(.caption).foregroundColor(.gray)
                                        }
                                    } else if squareEnd {
                                        Text("没有更多了").font(.caption).foregroundColor(.gray)
                                    } else {
                                        Text("上拉自动加载").font(.caption).foregroundColor(.gray)
                                    }
                                    // 兜底：自动触发失效时手动点
                                    if !squareEnd && !loadingMore {
                                        Button("加载更多") { loadMore() }
                                            .font(.subheadline).foregroundColor(.blue)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .onAppear {
                                    // 延迟触发避免 LazyVGrid 初始化误触
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loadMore() }
                                }
                            }
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $selected) { v in
                VideoDetailView(v: v, cache: cache)
            }
            .sheet(isPresented: $showLogin) {
                LoginView(onSuccess: { loggedIn = true; showLogin = false; load() })
            }
            .onAppear {
                loggedIn = (API.shared.token != nil)
                load()
            }
            .navigationViewStyle(.stack)
        }
    }

    private var currentList: [VideoItem] {
        [hotVideos, squareVideos, hotVideos][tab]
    }

    private func load() {
        loading = true; loadError = ""
        squarePage = 1; squareEnd = false
        Task {
            var items: [VideoItem] = []
            var err = ""
            switch tab {
            case 0:
                let l = await API.shared.videoList(page: 1)
                items = (l ?? []).map { VideoItem($0) }
                if l == nil { err = "加载失败" }
            case 1:
                let l = await API.shared.squareList(page: 1)
                items = (l ?? []).map { VideoItem($0) }
                if l == nil { err = "加载失败" }
            case 2:
                let l = await API.shared.attentionListUsers()
                await MainActor.run {
                    attentionUsers = l ?? []
                    if l == nil { loadError = "加载失败(需登录)" }
                    loading = false
                }
                return
            default: break
            }
            await MainActor.run {
                switch tab {
                case 0: hotVideos = items
                case 1: squareVideos = items
                default: break
                }
                loading = false
                loadError = err
            }
        }
    }

    private func loadMore() {
        guard !loadingMore && !squareEnd else { return }
        loadingMore = true
        squarePage += 1
        Task {
            let l = await API.shared.squareList(page: squarePage)
            await MainActor.run {
                let items = (l ?? []).map { VideoItem($0) }
                squareVideos += items
                if items.isEmpty { squareEnd = true }   // 空页=到底
                loadingMore = false
            }
        }
    }

    /// 点视频：打开详情页（详情页自己拉 detail/评论）
    private func tapVideo(_ v: VideoItem) {
        selected = v
    }
}

/// 封面图缓存（内存+磁盘，解决下滑后重新加载变黑）
final class ImageCache {
    static let shared = ImageCache()
    private let mem = NSCache<NSString, UIImage>()
    private var diskDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let p = d.appendingPathComponent("ImgCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p
    }
    private func diskURL(_ key: String) -> URL {
        diskDir.appendingPathComponent("img_" + String(key.hashValue.magnitude) + ".jpg")
    }
    func cachedImage(for url: URL?) -> UIImage? {
        guard let url = url else { return nil }
        if let m = mem.object(forKey: url.absoluteString as NSString) { return m }
        return UIImage(contentsOfFile: diskURL(url.absoluteString).path)
    }
    func load(url: URL?, completion: @escaping (UIImage?) -> Void) {
        guard let url = url else { completion(nil); return }
        if let hit = cachedImage(for: url) { completion(hit); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let img = UIImage(data: data) else { completion(nil); return }
            self.mem.setObject(img, forKey: url.absoluteString as NSString)
            try? data.write(to: self.diskURL(url.absoluteString))
            DispatchQueue.main.async { completion(img) }
        }.resume()
    }
}

/// 网格项：第一版排版（GeometryReader 固定高）+ ImageCache 防黑
struct VideoGridCell: View {
    let v: VideoItem
    @ObservedObject var cache: CacheStore
    @State private var img: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // 封面图（缓存，避免下滑重载变黑）
                if let img = img {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height - 25)
                        .clipped()
                } else {
                    Color.gray.opacity(0.25)
                        .frame(width: geo.size.width, height: geo.size.height - 25)
                    Color.clear.onAppear {
                        ImageCache.shared.load(url: v.coverURL.flatMap(URL.init)) { im in
                            self.img = im
                        }
                    }
                }

                // 底部白条：点赞数（APK item_videolist 白条）
                HStack(spacing: 4) {
                    Spacer()
                    Image(systemName: "heart.fill").font(.system(size: 12)).foregroundColor(.pink)
                    Text("\(v.likes)").font(.system(size: 12)).foregroundColor(.gray)
                }
                .padding(.horizontal, 5)
                .frame(height: 25)
                .background(Color.white)

                // 已缓存标记
                if cache.cachedURL(for: v.id) != nil {
                    VStack {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption).foregroundColor(.green)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(5)
                }
            }
        }
        .frame(height: UIScreen.main.bounds.width / 2 * 1.5)
    }
}

/// 视频详情页：顶部播放器 + 标题 + 点赞/收藏 + 评论列表（参考 APK activity_video_detail）
struct VideoDetailView: View {
    let v: VideoItem
    @ObservedObject var cache: CacheStore
    @Environment(\.dismiss) var dismiss

    // detail 自己拉（sheet 弹出后异步请求，请求完成自动刷新播放地址）
    @State private var detail: [String: Any]?
    @State private var comments: [CommentItem] = []
    @State private var commentText = ""
    @State private var liked = false
    @State private var collected = false
    @State private var followed = false
    @State private var actionMsg = ""
    @State private var authorProfile: AuthorProfile?

    // 播放地址：detail 接口返回的服务端CDN地址优先（老IP列表地址已失效）
    private var playerURL: URL? {
        if let cached = cache.cachedURL(for: v.id) { return cached }
        if let d = detail, let u = d["mv_play_url"] as? String { return URL(string: u) }
        return nil   // 只有 detail 返回才播（老地址必失效，避免播不了）
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        // 播放器
                        if let url = playerURL {
                            VideoPlayerView(url: url)
                                .frame(height: 250)
                        } else {
                            ZStack {
                                Rectangle().fill(Color.black).frame(height: 250)
                                if detail == nil {
                                    ProgressView().colorScheme(.light)
                                } else {
                                    Text("无播放地址").foregroundColor(.gray)
                                }
                            }
                        }

                        // 标题
                        Text(v.title)
                            .font(.headline).bold()
                            .padding(.horizontal, 12).padding(.top, 10)

                        // 作者 + 操作按钮行（点作者进TA主页）
                        HStack(spacing: 14) {
                            Button {
                                authorProfile = AuthorProfile(muId: v.authorUid, name: v.author)
                            } label: {
                                Label("@\(v.author)", systemImage: "person.circle")
                                    .font(.subheadline).foregroundColor(.blue)
                            }
                            Spacer()
                            Button {
                                Task {
                                    let r = await API.shared.likeVideo(mvId: v.id)
                                    await MainActor.run {
                                        actionMsg = (r?["code"] as? Int == 0) ? "点赞成功" : "点赞失败(需登录)"
                                        liked = true
                                    }
                                }
                            } label: {
                                Label("\(v.likes)", systemImage: liked ? "heart.fill" : "heart")
                                    .font(.subheadline).foregroundColor(liked ? .pink : .pink.opacity(0.6))
                            }
                            Button {
                                Task {
                                    let r = await API.shared.collectVideo(mvId: v.id)
                                    await MainActor.run {
                                        actionMsg = (r?["code"] as? Int == 0) ? "收藏成功" : "收藏失败(需登录)"
                                        collected = true
                                    }
                                }
                            } label: {
                                Label("收藏", systemImage: collected ? "star.fill" : "star")
                                    .font(.subheadline).foregroundColor(collected ? .yellow : .gray)
                            }
                            Button {
                                Task {
                                    let d = detail ?? [:]
                                    let target = d["mu_id"] as? String ?? v.authorUid
                                    let r = await API.shared.followUser(attentionId: target)
                                    await MainActor.run {
                                        let ok = (r?["code"] as? Int == 0)
                                        actionMsg = ok ? "关注成功" : "关注失败(需登录)"
                                        if ok { followed = true }
                                    }
                                }
                            } label: {
                                Label(followed ? "已关注" : "关注",
                                      systemImage: followed ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.subheadline).foregroundColor(followed ? .gray : .blue)
                            }
                            .disabled(followed)
                        }
                        .padding(.horizontal, 12).padding(.top, 6)

                        if !actionMsg.isEmpty {
                            Text(actionMsg).font(.caption).foregroundColor(.orange).padding(.horizontal, 12)
                        }

                        if let sz = cache.sizeText(for: v.id) {
                            Label("已缓存到本地 \(sz)", systemImage: "arrow.down.circle.fill")
                                .font(.caption).foregroundColor(.green).padding(.horizontal, 12)
                        }

                        Divider().padding(.top, 6)

                        // 评论列表
                        HStack {
                            Text("评论 (\(comments.count))").font(.subheadline).bold()
                            Spacer()
                        }.padding(.horizontal, 12)

                        if comments.isEmpty {
                            Text("暂无评论").font(.caption).foregroundColor(.gray)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                        } else {
                            ForEach(comments) { c in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(c.user).font(.caption).bold()
                                        Spacer()
                                        Text(c.date).font(.caption2).foregroundColor(.gray)
                                    }
                                    Text(c.content).font(.subheadline)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 5)
                            }
                        }
                    }
                }

                // 底部评论输入栏（参考 APK video_detail_edit_layout）
                HStack {
                    TextField("说点什么...", text: $commentText)
                        .textFieldStyle(.roundedBorder)
                    Button("发送") { sendComment() }
                        .buttonStyle(.borderedProminent)
                        .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(8)
                .background(Color(UIColor.systemBackground))
            }
            .sheet(item: $authorProfile) { ap in
                AuthorProfileView(profile: ap)
            }
            .navigationTitle("视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                loadDetail()
                loadComments()
            }
            .navigationViewStyle(.stack)
        }
    }

    private func loadDetail() {
        Task {
            let d = await API.shared.videoDetail(mvId: v.id)
            await MainActor.run {
                detail = d
                if let d = d {
                    func asInt(_ v: Any?) -> Int {
                        if let n = v as? Int { return n }
                        if let s = v as? String { return Int(s) ?? 0 }
                        if let d = v as? Double { return Int(d) }
                        return 0
                    }
                    collected = asInt(d["is_collect"]) == 1
                    followed = asInt(d["is_attention"]) == 1
                    // 播放地址就绪后立即后台缓存
                    if let remote = d["mv_play_url"] as? String, let u = URL(string: remote) {
                        cache.cacheVideo(remote: u, id: v.id, author: v.author, title: v.title)
                    }
                }
            }
        }
    }

    private func loadComments() {
        Task {
            let list = await API.shared.comments(mvId: v.id) ?? []
            let models = list.enumerated().map { CommentItem($1, index: $0) }
            await MainActor.run { comments = models }
        }
    }

    private func sendComment() {
        let text = commentText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            let r = await API.shared.addComment(mvId: v.id, content: text)
            await MainActor.run {
                let code = r?["code"] as? Int ?? -1
                if code == 0 {
                    commentText = ""
                    loadComments()
                } else {
                    actionMsg = "评论失败: \(r?["message"] as? String ?? "code=\(code)")"
                }
            }
        }
    }
}

/// 播放器：AVPlayer 直接播远程URL（边下边播），本地缓存优先
struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // 激活播放音频会话（否则静音键开着/后台时无声）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.player?.play()
        vc.videoGravity = .resizeAspect
        return vc
    }
    func updateUIViewController(_ u: AVPlayerViewController, context: Context) {}
}

/// 作者入口数据
struct AuthorProfile: Identifiable {
    let id = UUID()
    let muId: String
    let name: String
}

/// 作者主页：资料 + TA的作品（listAll 拉广场页后本地过滤）
struct AuthorProfileView: View {
    let profile: AuthorProfile
    @State private var videos: [VideoItem] = []
    @State private var loading = true

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 54)).foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(profile.name).font(.title3).bold()
                            Text("uid: \(profile.muId)").font(.caption).foregroundColor(.gray)
                        }
                        Spacer()
                        NavigationLink {
                            ChatDetailView(otherUid: profile.muId, otherName: profile.name)
                        } label: {
                            Label("私信TA", systemImage: "bubble.left.and.bubble.right")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Text("TA的作品 (\(videos.count))").font(.subheadline).bold()
                        .padding(.horizontal)

                    if loading {
                        ProgressView().padding(30).frame(maxWidth: .infinity)
                    } else if videos.isEmpty {
                        Text("暂无作品").font(.caption).foregroundColor(.gray)
                            .padding(.horizontal).padding(.vertical, 8)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(),spacing:2),GridItem(.flexible(),spacing:2)], spacing: 2) {
                            ForEach(videos) { v in
                                VideoGridCell(v: v, cache: .shared)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
            .navigationTitle("作者主页")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { load() }
    }

    private func load() {
        Task {
            // 拉前5页广场，本地过滤该作者
            var mine: [VideoItem] = []
            for pg in 1...5 {
                let l = await API.shared.squareList(page: pg) ?? []
                let filtered = l.map { VideoItem($0) }.filter { $0.authorUid == profile.muId }
                mine += filtered
                if l.isEmpty { break }
            }
            await MainActor.run {
                videos = mine
                loading = false
            }
        }
    }
}

/// 与某作者的私信对话页（服务端当前维护中，接口已按抓包协议接入）
struct ChatDetailView: View {
    let otherUid: String
    let otherName: String
    @State private var messages: [[String: Any]] = []
    @State private var text = ""
    @State private var msg = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    if messages.isEmpty {
                        Text(msg.isEmpty ? "暂无消息" : msg).font(.caption).foregroundColor(.gray)
                            .padding(.top, 30)
                    } else {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                            HStack {
                                Text(m["mc_text"] as? String ?? m["content"] as? String ?? "")
                                    .font(.subheadline).padding(10)
                                    .background(Color.blue.opacity(0.15)).cornerRadius(12)
                                Spacer()
                            }.padding(.horizontal, 12)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            HStack {
                TextField("发消息...", text: $text).textFieldStyle(.roundedBorder)
                Button("发送") { send() }.buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(8)
        }
        .navigationTitle(otherName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
    }

    private func load() {
        Task {
            let l = await API.shared.oneChats(otherUid: otherUid) ?? []
            await MainActor.run { messages = l }
        }
    }
    private func send() {
        let c = text.trimmingCharacters(in: .whitespaces)
        Task {
            let r = await API.shared.sendMsg(toUid: otherUid, content: c)
            await MainActor.run {
                if r?["code"] as? Int == 0 { text = ""; load() }
                else { msg = r?["message"] as? String ?? "发送失败" }
            }
        }
    }
}
