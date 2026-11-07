import AuthenticationServices
import HESHShared
import UIKit

/// Passkey native (WebAuthn, RP hesh.it) con AuthenticationServices.
@MainActor
final class PasskeyManager: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = PasskeyManager()
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    enum PasskeyError: Error, LocalizedError {
        case cancelled, unexpected, server(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: "Operazione annullata"
            case .unexpected: "Risposta passkey inattesa"
            case .server(let s): s
            }
        }
    }

    // MARK: Registrazione (utente loggato)

    func createPasskey(name: String = UIDevice.current.name) async throws {
        let (challengeId, opts) = try await APIClient.shared.passkeyRegisterOptions()
        guard let challenge = (opts["challenge"] as? String).flatMap(Self.b64urlDecode),
              let user = opts["user"] as? [String: Any],
              let userId = (user["id"] as? String).flatMap(Self.b64urlDecode),
              let userName = user["name"] as? String,
              let rp = opts["rp"] as? [String: Any], let rpId = rp["id"] as? String else { throw PasskeyError.unexpected }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: userName, userID: userId)
        request.userVerificationPreference = .required
        let auth = try await perform([request])
        guard let cred = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = cred.rawAttestationObject else { throw PasskeyError.unexpected }
        let json: [String: Any] = [
            "id": Self.b64url(cred.credentialID), "rawId": Self.b64url(cred.credentialID), "type": "public-key",
            "response": ["attestationObject": Self.b64url(attestation), "clientDataJSON": Self.b64url(cred.rawClientDataJSON)],
        ]
        try await APIClient.shared.passkeyRegister(challengeId: challengeId, credential: json, name: name)
    }

    // MARK: Login (nuovo dispositivo)

    func login(username: String) async throws -> RegisterResponse {
        let (challengeId, opts) = try await APIClient.shared.passkeyLoginOptions(username: username)
        guard let challenge = (opts["challenge"] as? String).flatMap(Self.b64urlDecode),
              let rpId = opts["rpId"] as? String else { throw PasskeyError.unexpected }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        if let allowed = opts["allowCredentials"] as? [[String: Any]] {
            request.allowedCredentials = allowed.compactMap { ($0["id"] as? String).flatMap(Self.b64urlDecode) }
                .map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        }
        let auth = try await perform([request])
        guard let cred = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { throw PasskeyError.unexpected }
        let json: [String: Any] = [
            "id": Self.b64url(cred.credentialID), "rawId": Self.b64url(cred.credentialID), "type": "public-key",
            "response": [
                "authenticatorData": Self.b64url(cred.rawAuthenticatorData),
                "clientDataJSON": Self.b64url(cred.rawClientDataJSON),
                "signature": Self.b64url(cred.signature),
                "userHandle": Self.b64url(cred.userID),
            ],
        ]
        return try await APIClient.shared.passkeyLogin(challengeId: challengeId, credential: json, deviceName: UIDevice.current.name)
    }

    // MARK: Plumbing

    private func perform(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let e = error as? ASAuthorizationError, e.code == .canceled { continuation?.resume(throwing: PasskeyError.cancelled) }
        else { continuation?.resume(throwing: error) }
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func b64urlDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)
    }
}
