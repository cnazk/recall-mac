import Foundation
import OSLog
import RecallOTP

let log = Logger(subsystem: "com.recall.otp", category: "listener")

/// A self-check, so the sandbox and Keychain wiring can be proven from the command line
/// before anything is built on top of it: `… --selftest`.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

/// Only Recall may talk to this helper.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The helper is an XPCService inside Recall.app, so launchd will only ever start
        // it on behalf of that app — but the requirement is checked anyway. A helper that
        // accepts any caller is worse than no helper at all.
        connection.setCodeSigningRequirement(OTPService.callerCodeSigningRequirement(teamIdentifier: teamIdentifier))

        connection.exportedInterface = NSXPCInterface(with: OTPServiceProtocol.self)
        connection.exportedObject = OTPServiceImplementation()
        connection.resume()
        return true
    }

    /// The team the helper itself was signed with; an ad-hoc development build has none.
    private var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code as! SecStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any]
        else { return nil }

        return details["teamid"] as? String
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
log.info("Recall two-factor helper listening")
listener.resume()
