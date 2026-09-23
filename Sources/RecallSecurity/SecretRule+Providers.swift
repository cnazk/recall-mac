import Foundation
import RecallCore

/// Rules for credential formats with unmistakable shapes.
///
/// Each of these is a published, fixed prefix-and-length, which is why they sit at
/// `.certain`: the false-positive rate is effectively zero, and a clip that matches one
/// really is a live credential.
public extension SecretRule {
    static let stripeKey = SecretRule(
        identifier: "stripe.key",
        displayName: String(localized: "Stripe key"),
        summary: String(localized: "Live secret, restricted and publishable keys."),
        confidence: .certain,
        pattern: "\\b(sk|rk|pk)_(live|test)_[0-9a-zA-Z]{20,}\\b"
    )

    static let slackToken = SecretRule(
        identifier: "slack.token",
        displayName: String(localized: "Slack token"),
        summary: String(localized: "Bot, user and app tokens (xoxb-, xoxp-…)."),
        confidence: .certain,
        pattern: "\\bxox[baprs]-[0-9A-Za-z-]{10,}\\b"
    )

    static let gitlabToken = SecretRule(
        identifier: "gitlab.token",
        displayName: String(localized: "GitLab token"),
        summary: String(localized: "Personal access tokens (glpat-)."),
        confidence: .certain,
        pattern: "\\bglpat-[0-9A-Za-z_-]{20,}\\b"
    )

    static let googleAPIKey = SecretRule(
        identifier: "google.api-key",
        displayName: String(localized: "Google API key"),
        summary: String(localized: "Keys beginning AIza."),
        confidence: .certain,
        pattern: "\\bAIza[0-9A-Za-z_-]{35}\\b"
    )

    static let huggingFaceToken = SecretRule(
        identifier: "huggingface.token",
        displayName: String(localized: "Hugging Face token"),
        summary: String(localized: "Access tokens (hf_)."),
        confidence: .certain,
        pattern: "\\bhf_[0-9A-Za-z]{30,}\\b"
    )

    static let anthropicKey = SecretRule(
        identifier: "anthropic.key",
        displayName: String(localized: "Anthropic API key"),
        summary: String(localized: "Keys beginning sk-ant-."),
        confidence: .certain,
        pattern: "\\bsk-ant-[0-9A-Za-z_-]{20,}\\b"
    )

    static let npmToken = SecretRule(
        identifier: "npm.token",
        displayName: String(localized: "npm token"),
        summary: String(localized: "Automation and publish tokens (npm_)."),
        confidence: .certain,
        pattern: "\\bnpm_[0-9A-Za-z]{30,}\\b"
    )

    static let twilioKey = SecretRule(
        identifier: "twilio.key",
        displayName: String(localized: "Twilio identifier"),
        summary: String(localized: "Account and API SIDs (AC…, SK… plus 32 hex)."),
        confidence: .certain,
        pattern: "\\b(AC|SK)[0-9a-fA-F]{32}\\b"
    )

    static let sendGridKey = SecretRule(
        identifier: "sendgrid.key",
        displayName: String(localized: "SendGrid key"),
        summary: String(localized: "Keys beginning SG. with two segments."),
        confidence: .certain,
        pattern: "\\bSG\\.[0-9A-Za-z_-]{16,}\\.[0-9A-Za-z_-]{16,}\\b"
    )

    static let discordBotToken = SecretRule(
        identifier: "discord.bot-token",
        displayName: String(localized: "Discord bot token"),
        summary: String(localized: "Three dot-separated segments issued to bots."),
        confidence: .likely,
        pattern: "\\b[MNO][0-9A-Za-z_-]{23,}\\.[0-9A-Za-z_-]{6}\\.[0-9A-Za-z_-]{27,}\\b"
    )

    static let telegramBotToken = SecretRule(
        identifier: "telegram.bot-token",
        displayName: String(localized: "Telegram bot token"),
        summary: String(localized: "A numeric id, a colon, then 35 characters."),
        confidence: .certain,
        pattern: "\\b[0-9]{8,10}:[A-Za-z0-9_-]{35}\\b"
    )

    static let cloudflareToken = SecretRule(
        identifier: "cloudflare.token",
        displayName: String(localized: "Cloudflare token"),
        summary: String(localized: "API tokens beginning v1.0-."),
        confidence: .certain,
        pattern: "\\bv1\\.0-[0-9a-fA-F]{20,}-[0-9a-fA-F]{20,}\\b"
    )

    /// Apple's app-specific passwords are four lowercase groups of four.
    static let appSpecificPassword = SecretRule(
        identifier: "apple.app-password",
        displayName: String(localized: "App-specific password"),
        summary: String(localized: "Apple's xxxx-xxxx-xxxx-xxxx passwords."),
        confidence: .likely
    ) { text in
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Required to be the whole clip: this shape also occurs inside licence keys.
        guard trimmed.count == 19 else { return false }
        let groups = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 4 else { return false }
        return groups.allSatisfy { group in
            group.count == 4 && group.allSatisfy { $0.isLowercase && $0.isLetter }
        }
    }

    /// `scheme://user:password@host` — the credential is right there in the URL.
    static let basicAuthURL = SecretRule(
        identifier: "url.basic-auth",
        displayName: String(localized: "URL with a password"),
        summary: String(localized: "Links carrying user:password@ credentials."),
        confidence: .certain,
        pattern: "\\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\\s:@/]+:[^\\s:@/]+@[^\\s/]+"
    )

    static let databaseURL = SecretRule(
        identifier: "url.database",
        displayName: String(localized: "Database connection string"),
        summary: String(localized: "postgres://, mysql://, mongodb+srv:// with a password."),
        confidence: .certain,
        pattern: "\\b(postgres(ql)?|mysql|mongodb(\\+srv)?|redis|amqp)://[^\\s:@/]+:[^\\s:@/]+@"
    )

    /// Three or more `KEY=value` lines where at least one key looks like a secret.
    static let environmentFile = SecretRule(
        identifier: "env.file",
        displayName: String(localized: "Environment file"),
        summary: String(localized: "A block of KEY=value lines including a secret-looking key."),
        confidence: .likely
    ) { text in
        let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 3 else { return false }

        let assignments = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "="), equals > trimmed.startIndex else { return false }
            let key = trimmed[trimmed.startIndex..<equals]
            return key.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
        }
        guard assignments.count >= 3 else { return false }

        let sensitive = ["SECRET", "TOKEN", "PASSWORD", "PASSWD", "KEY", "CREDENTIAL", "PRIVATE"]
        return assignments.contains { line in
            sensitive.contains { line.uppercased().contains($0) }
        }
    }

    static let kubeConfig = SecretRule(
        identifier: "kubernetes.config",
        displayName: String(localized: "Kubernetes config"),
        summary: String(localized: "kubeconfig carrying client keys or tokens."),
        confidence: .likely,
        pattern: "(?s)apiVersion:\\s*v1.*(client-key-data|client-certificate-data|token):\\s*\\S+"
    )
}
