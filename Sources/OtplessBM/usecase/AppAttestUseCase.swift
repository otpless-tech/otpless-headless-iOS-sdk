//
//  AppAttestUseCase.swift
//  OtplessBM
//

import CryptoKit
import DeviceCheck
import Foundation

@available(iOS 14.0, *)
internal final class AppAttestUseCase {

    private let keyIdStorageKey = "otpless_bm_attest_key_id"

    // MARK: - Key management

    func hasAttestationKey() -> Bool {
        getKeyId() != nil
    }

    func getKeyId() -> String? {
        SecureStorage.shared.retrieve(key: keyIdStorageKey)
    }

    private func saveKeyId(_ keyId: String) {
        SecureStorage.shared.save(key: keyIdStorageKey, value: keyId)
    }

    // MARK: - Backend

    /// Posts the attestation object to the backend.
    /// Returns true when the backend accepts it.
    /// Replace the placeholder body with a real API call when the endpoint is ready.
    private func postAttestation(keyId: String, attestationObject: Data) async -> Bool {
        let base64 = attestationObject.base64EncodedString()
        print("[AppAttest] POST attestation — keyId: \(keyId.prefix(8))…")
        print("[AppAttest] Attestation object (\(attestationObject.count) bytes, base64):\n\(base64)")
        // TODO: replace with real backend call, e.g.:
        // let result = await Otpless.shared.apiRepository.postAttestation(keyId: keyId, attestationObject: base64)
        return true
    }

    // MARK: - Assertion

    /// Generates a cryptographic assertion for a single request.
    /// - Parameters:
    ///   - nonce: Fresh server-issued challenge for this request.
    ///   - canonicalPayload: Stable string representation of critical request fields,
    ///     e.g. "\(channel)|\(identifier)|\(identifierType)".
    /// - Returns: Base64-encoded assertion object to attach to the request, or nil on failure.
    func generateAssertion(nonce: String, canonicalPayload: String) async -> String? {
        guard DCAppAttestService.shared.isSupported else {
            DLog("[AppAttest] App Attest not supported — cannot generate assertion")
            return nil
        }

        guard let keyId = SecureStorage.shared.retrieve(key: keyIdStorageKey) else {
            DLog("[AppAttest] No keyId found — device must be attested before generating assertions")
            return nil
        }

        do {
            let combined = nonce + canonicalPayload
            let clientData = Data(SHA256.hash(data: Data(combined.utf8)))

            DLog("[AppAttest] Generating assertion for keyId: \(keyId.prefix(8))…")
            let assertionObject = try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientData)

            let base64 = assertionObject.base64EncodedString()
            DLog("[AppAttest] Assertion generated (\(assertionObject.count) bytes)")
            return base64
        } catch {
            DLog("[AppAttest] Assertion failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Attestation

    /// Attest the device using the provided nonce.
    /// Pass a server-issued nonce when the backend endpoint is ready;
    /// call with a random UUID as a placeholder until then.
    func attest(nonce: String) async {
        guard DCAppAttestService.shared.isSupported else {
            DLog("[AppAttest] App Attest not supported on this device — skipping")
            return
        }

        guard !hasAttestationKey() else {
            DLog("[AppAttest] Already attested — skipping")
            return
        }

        do {
            DLog("[AppAttest] Generating new key")
            let keyId = try await DCAppAttestService.shared.generateKey()

            let clientDataHash = Data(SHA256.hash(data: Data(nonce.utf8)))

            DLog("[AppAttest] Attesting keyId: \(keyId.prefix(8))…")
            let attestationObject = try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)

            let backendAccepted = await postAttestation(keyId: keyId, attestationObject: attestationObject)
            guard backendAccepted else {
                DLog("[AppAttest] Backend rejected attestation — keyId not persisted")
                return
            }

            // Persist only after backend confirms — hasAttestationKey() is the source of truth.
            saveKeyId(keyId)
            DLog("[AppAttest] Attestation complete and keyId persisted")
        } catch {
            DLog("[AppAttest] Attestation failed: \(error.localizedDescription)")
        }
    }
}
