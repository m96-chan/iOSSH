import Foundation

enum TailscaleAuthentication {
    /// Only Tailscale HTTPS links become sign-in actions. Other server text remains selectable.
    static func loginURL(in banner: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(banner.startIndex..<banner.endIndex, in: banner)
        return detector.matches(in: banner, range: range).compactMap(\.url).first { url in
            guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
            return host == "tailscale.com" || host.hasSuffix(".tailscale.com")
        }
    }
}
