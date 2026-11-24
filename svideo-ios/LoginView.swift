import SwiftUI

/// 根视图：直接进入视频列表；登录按需从右上角入口进入
struct RootView: View {
    var body: some View {
        VideoFeedView()
    }
}

/// 账号页：已登录显示资料（getUserInfo），未登录显示登录表单
struct LoginView: View {
    let onSuccess: () -> Void
    @State private var phone = ""
    @State private var password = ""
    @State private var busy = false
    @State private var msg = ""
    @State private var profile: [String: Any]?
    @State private var loadingProfile = false

    var body: some View {
        NavigationView {
            Group {
                if let p = profile {
                    profileView(p)
                } else {
                    loginForm
                }
            }
            .navigationTitle("账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { onSuccess() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if profile != nil {
                        Button("退出登录", role: .destructive) {
                            API.shared.token = nil
                            UserDefaults.standard.removeObject(forKey: "mu_id")
                            profile = nil
                        }
                    }
                }
            }
            .onAppear {
                if API.shared.token != nil && profile == nil { loadProfile() }
            }
            .navigationViewStyle(.stack)
        }
    }

    // MARK: - 登录表单
    private var loginForm: some View {
        VStack(spacing: 20) {
            Text("快猫").font(.largeTitle).bold()
            TextField("邮箱账号", text: $phone)
                .textFieldStyle(.roundedBorder).keyboardType(.emailAddress)
                .autocapitalization(.none).disableAutocorrection(true)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await doLogin() }
            } label: {
                if busy { ProgressView() } else { Text("登录").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent).disabled(busy)
            Text(msg).font(.caption).foregroundColor(.red).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    // MARK: - 用户资料（参考 getUserInfo 字段 mu_*）
    private func profileView(_ p: [String: Any]) -> some View {
        List {
            HStack {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 56)).foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p["mu_name"] as? String ?? "用户").font(.title3).bold()
                    Text(p["mu_email"] as? String ?? "").font(.caption).foregroundColor(.gray)
                }
            }
            .padding(.vertical, 8)
            Section("资产") {
                Row("金币", p["mu_coins"] as? String)
                Row("积分", p["mu_points"] as? String)
                Label(p["mu_vip_type"] as? String == "0" ? "非会员" : "VIP会员",
                      systemImage: p["mu_vip_type"] as? String == "0" ? "person" : "crown.fill")
                    .foregroundColor(p["mu_vip_type"] as? String == "0" ? .gray : .yellow)
            }
            Section {
                NavigationLink {
                    CollectListView()
                } label: {
                    Label("我的收藏", systemImage: "star")
                }
                NavigationLink {
                    MessagesView()
                } label: {
                    Label("私信", systemImage: "bubble.left.and.bubble.right")
                }
            }
            Section("社交") {
                Row("关注", p["mu_me_attention_count"] as? String)
                Row("粉丝", p["mu_attention_me_count"] as? String)
            }
        }
    }

    private func Row(_ label: String, _ value: String?) -> some View {
        HStack { Text(label); Spacer(); Text(value ?? "-").foregroundColor(.secondary) }
    }

    // MARK: - 逻辑
    private func doLogin() async {
        busy = true; msg = ""
        let r = await API.shared.login(phone: phone, password: password)
        await MainActor.run {
            busy = false
            let code = r?["code"] as? Int ?? -1
            // 服务端成功码是 0（抓包确认），兼容 200
            if code == 0 || code == 200 {
                // 登录成功 → 拉用户资料展示
                loadProfile()
            } else {
                msg = "登录失败: \(r?["message"] as? String ?? r?["msg"] as? String ?? "code=\(code)")"
            }
        }
    }

    private func loadProfile() {
        loadingProfile = true
        Task {
            let p = await API.shared.userInfo()
            await MainActor.run {
                loadingProfile = false
                if let p = p, (p["mu_id"] as? String) != nil {
                    profile = p
                } else {
                    // token 失效 → 显示登录表单
                    API.shared.token = nil
                }
            }
        }
    }
}

/// 我的收藏列表（/api/community/videoCollectList）
struct CollectListView: View {
    @ObservedObject private var cache = CacheStore.shared
    @State private var items: [VideoItem] = []
    @State private var loading = true
    @State private var selected: VideoItem?

    var body: some View {
        Group {
            if loading {
                VStack { ProgressView(); Text("加载中...").font(.caption) }.padding(30)
            } else if items.isEmpty {
                VStack { Image(systemName: "star.slash").font(.largeTitle).foregroundColor(.gray)
                         Text("暂无收藏").foregroundColor(.gray) }.padding(30)
            } else {
                List {
                    ForEach(items) { v in
                        HStack {
                            CachedThumb(url: v.coverURL)
                                .frame(width: 90, height: 60).clipped().cornerRadius(6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(v.title).font(.subheadline).lineLimit(2)
                                Text(v.author).font(.caption).foregroundColor(.gray)
                            }
                            Spacer()
                        }
                        .onTapGesture { selected = v }
                    }
                    // 滚到底自动加载下一页
                    Color.clear.frame(height: 50).onAppear { loadMore() }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { v in
            VideoDetailView(v: v, cache: cache)
        }
        .onAppear { load() }
    }

    @State private var page = 1
    private func load() {
        page = 1
        Task {
            let l = (await API.shared.collectList(page: 1) ?? []).map { VideoItem($0) }
            await MainActor.run { items = l; loading = false }
        }
    }
    private func loadMore() {
        page += 1
        Task {
            let l = (await API.shared.collectList(page: page) ?? []).map { VideoItem($0) }
            await MainActor.run { items += l }
        }
    }
}

/// 私信列表（/api/chats/getChatUsers）
struct MessagesView: View {
    @State private var items: [[String: Any]] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                VStack { ProgressView(); Text("加载中...").font(.caption) }.padding(30)
            } else if items.isEmpty {
                VStack { Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundColor(.gray)
                         Text("暂无私信").foregroundColor(.gray) }.padding(30)
            } else {
                List {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, c in
                        HStack(spacing: 10) {
                            Image(systemName: "person.circle.fill").font(.system(size: 40)).foregroundColor(.gray)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c["mu_name"] as? String ?? "用户").font(.subheadline).bold()
                                Text(c["last_msg"] as? String ?? "").font(.caption).foregroundColor(.gray).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("私信")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
    }

    private func load() {
        Task {
            let r = await API.shared.chatUsers()
            await MainActor.run {
                items = r ?? []
                loading = false
            }
        }
    }
}

/// 缓存缩略图（复用 ImageCache，防下滑变灰）
struct CachedThumb: View {
    let url: String?
    @State private var img: UIImage?

    var body: some View {
        Group {
            if let img = img { Image(uiImage: img).resizable().scaledToFill() }
            else { Color.gray.opacity(0.3) }
        }
        .onAppear {
            ImageCache.shared.load(url: url.flatMap(URL.init)) { im in
                self.img = im
            }
        }
    }
}
