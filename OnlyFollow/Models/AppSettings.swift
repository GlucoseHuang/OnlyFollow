import Foundation

/// App 全局设置，持久化到 UserDefaults
enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - B站 Cookie

    /// 用户从浏览器复制的完整 B站 cookie 字符串，或二维码登录保存的 cookie
    /// 包含 SESSDATA、bili_jct、DedeUserID 等
    static var bilibiliCookie: String {
        get { defaults.string(forKey: "bilibili_cookie") ?? "" }
        set { defaults.set(newValue, forKey: "bilibili_cookie") }
    }

    static var hasBilibiliCookie: Bool { !bilibiliCookie.isEmpty }

    /// 从 cookie 字符串中提取 bili_jct（B站 CSRF Token）
    static var bilibiliJct: String {
        for part in bilibiliCookie.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("bili_jct=") {
                return String(trimmed.dropFirst("bili_jct=".count))
            }
        }
        return ""
    }

    /// 上次验证登录的时间
    static var bilibiliLastVerifiedAt: Date {
        get { defaults.object(forKey: "bilibili_last_verified") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "bilibili_last_verified") }
    }

    /// 已登录用户的 uid
    static var bilibiliLoggedUID: Int {
        get { defaults.integer(forKey: "bilibili_logged_uid") }
        set { defaults.set(newValue, forKey: "bilibili_logged_uid") }
    }

    /// 已登录用户的昵称（展示用）
    static var bilibiliLoggedName: String {
        get { defaults.string(forKey: "bilibili_logged_name") ?? "" }
        set { defaults.set(newValue, forKey: "bilibili_logged_name") }
    }

    // MARK: - 抖音 Cookie

    static var douyinCookie: String {
        get { defaults.string(forKey: "douyin_cookie") ?? "" }
        set { defaults.set(newValue, forKey: "douyin_cookie") }
    }

    static var hasDouyinCookie: Bool { !douyinCookie.isEmpty }

    // MARK: - 通用辅助

    /// 清空 B站登录态（保留 cookie 字段供用户排查，但清掉验证记录）
    static func clearBilibiliLoginRecord() {
        defaults.removeObject(forKey: "bilibili_last_verified")
        defaults.removeObject(forKey: "bilibili_logged_uid")
        defaults.removeObject(forKey: "bilibili_logged_name")
    }
}
