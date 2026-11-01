import CryptoKit
import Foundation

/// A self-contained browser receipt. Token exchange and verification continue in Tern.
struct AuthCallbackPage {
    enum State {
        case received, notCompleted, unmatchedRequest

        init(callbackURL: URL) {
            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let codes = items.filter { $0.name == "code" }
            self = !items.contains(where: { $0.name == "error" })
                && codes.count == 1 && codes[0].value?.isEmpty == false ? .received : .notCompleted
        }

        fileprivate var caption: String {
            switch self {
            case .received: "Browser step complete"
            case .notCompleted: "Sign-in not completed"
            case .unmatchedRequest: "Sign-in link not recognized"
            }
        }

        fileprivate var title: String {
            switch self {
            case .received: "Back to Tern"
            case .notCompleted: "Return to Tern"
            case .unmatchedRequest: "This link doesn't match"
            }
        }

        fileprivate var message: String {
            switch self {
            case .received: "Tern received your ChatGPT sign-in and is checking the connection."
            case .notCompleted: "ChatGPT sign-in wasn't completed. You can try again from Assistant settings in Tern."
            case .unmatchedRequest: "Return to the browser tab where you started signing in, or start again from Assistant settings in Tern."
            }
        }

        fileprivate var nextStep: String {
            switch self {
            case .received: "Continue in Tern to see your connection status."
            case .notCompleted: "Your connection status is shown in the app."
            case .unmatchedRequest: "Continue from your original sign-in tab."
            }
        }
    }

    let state: State
    private let logoPNG: Data?

    init(state: State, logoPNG: Data? = nil) {
        self.state = state
        self.logoPNG = logoPNG ?? Self.bundledLogoPNG
    }

    private static let bundledLogoPNG: Data? = {
        guard let url = Bundle.main.url(forResource: "TernSignInLogo", withExtension: "png") else { return nil }
        return try? Data(contentsOf: url)
    }()

    static let contentSecurityPolicy = "default-src 'none'; style-src 'sha256-"
        + Data(SHA256.hash(data: Data(styles.utf8))).base64EncodedString()
        + "'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    var html: String {
        let statusClass = state == .received ? "received" : "incomplete"
        let statusSymbol = state == .received
            ? "<path d=\"m7 12 3 3 7-7\"/>"
            : "<path d=\"M12 7v6m0 4h.01\"/>"
        let logo = logoPNG.map {
            "<img class=\"envelope\" src=\"data:image/png;base64,\($0.base64EncodedString())\" alt=\"\">"
        } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          <title>\(state.title) · Tern</title>
          <style>\(Self.styles)</style>
        </head>
        <body>
          <main aria-labelledby="title" class="\(statusClass)">
            <div class="brand">Tern <span class="brand-divider" aria-hidden="true"></span><span>ChatGPT sign-in</span></div>
            <div class="content">
              <div class="illustration" aria-hidden="true">
                \(logo)
                <span class="stamp"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\(statusSymbol)</svg></span>
              </div>
              <p class="caption">\(state.caption)</p>
              <h1 id="title">\(state.title)</h1>
              <p class="message">\(state.message)</p>
            </div>
            <footer>
              <p class="close-note">You can close this tab</p>
              <p class="next-step">\(state.nextStep)</p>
            </footer>
          </main>
        </body>
        </html>
        """
    }

    // Web counterparts of the workspace's Apple Minimal design tokens.
    private static let styles = """
    :root {
      color-scheme: light dark;
      --canvas: #FAFAFA; --surface: #FFFFFF; --fg: #18181B; --muted: #52525B;
      --border: #E4E4E7; --border-strong: #D4D4D8;
      --status-bg: #DCFCE7; --status-fg: #166534;
      --warning-bg: #FEF3C7; --warning-fg: #92400E;
      --s1: 4px; --s2: 8px; --s3: 12px; --s4: 16px; --s5: 20px;
      --s6: 24px; --s8: 32px; --s10: 40px; --s12: 48px; --s16: 64px;
      --radius: 14px; --round: 9999px; --hairline: 1px; --stroke: 2px;
      --text-sm: 14px; --text-base: 16px; --text-lg: 18px; --title: 36px; --title-compact: 30px;
      --regular: 400; --medium: 500; --semibold: 600;
      --leading: 1.5; --tight: 1.2; --tracking: -0.01em;
      --shadow: 0 18px 50px rgba(0, 0, 0, 0.16);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: var(--canvas); color: var(--fg);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; min-height: 100vh; min-height: 100svh;
      display: grid; place-items: center; padding: var(--s6);
      font-size: var(--text-base); line-height: var(--leading); font-weight: var(--regular);
    }
    main {
      width: 100%; max-width: calc(var(--s16) * 8);
      background: var(--surface); border: var(--hairline) solid var(--border);
      border-radius: var(--radius); box-shadow: var(--shadow); overflow-wrap: anywhere;
    }
    .brand {
      display: flex; flex-wrap: wrap; align-items: center; justify-content: center;
      gap: var(--s3); padding: var(--s6); border-bottom: var(--hairline) solid var(--border);
      font-size: var(--text-lg); font-weight: var(--semibold);
    }
    .brand > span:last-child { color: var(--muted); font-size: var(--text-sm); font-weight: var(--regular); }
    .brand-divider { height: var(--s4); width: var(--hairline); background: var(--border-strong); }
    .content { padding: var(--s12) var(--s12) var(--s10); text-align: center; }
    .illustration { position: relative; width: calc(var(--s12) * 2); height: calc(var(--s12) * 2); margin: 0 auto var(--s8); }
    .envelope { display: block; width: 100%; height: 100%; object-fit: contain; }
    .stamp {
      position: absolute; right: 0; bottom: 0; display: grid; place-items: center;
      width: var(--s8); height: var(--s8); border-radius: var(--round);
      border: var(--stroke) solid var(--surface); color: var(--status-fg); background: var(--status-bg);
    }
    .stamp svg { width: var(--s5); height: var(--s5); }
    .caption { color: var(--status-fg); font-size: var(--text-sm); font-weight: var(--medium); margin: 0 0 var(--s3); }
    .incomplete .stamp { color: var(--warning-fg); background: var(--warning-bg); }
    .incomplete .caption { color: var(--warning-fg); }
    h1 { margin: 0; font-size: var(--title); line-height: var(--tight); letter-spacing: var(--tracking); font-weight: var(--semibold); }
    .message { color: var(--muted); margin: var(--s4) 0 0; }
    footer { padding: var(--s6); border-top: var(--hairline) solid var(--border); text-align: center; }
    .close-note { margin: 0; font-size: var(--text-sm); font-weight: var(--medium); }
    .next-step { margin: var(--s1) 0 0; color: var(--muted); font-size: var(--text-sm); }
    @media (prefers-color-scheme: dark) {
      :root {
        --canvas: #0A0A0B; --surface: #18181B; --fg: #F4F4F5; --muted: #A1A1AA;
        --border: #27272A; --border-strong: #3F3F46;
        --status-bg: #14532D; --status-fg: #86EFAC;
        --warning-bg: #78350F; --warning-fg: #FDE68A;
      }
    }
    @media (max-width: 640px) {
      body { padding: var(--s4); }
      .content { padding: var(--s8) var(--s6); }
      h1 { font-size: var(--title-compact); }
    }
    @media (prefers-contrast: more) {
      :root { --muted: var(--fg); --border: var(--fg); --border-strong: var(--fg); }
      main { box-shadow: none; }
    }
    """
}
