import Foundation
import LocalAuthentication
import BuildSightKit

/// Face ID / Touch ID. No passcode fallback: if biometrics lock out, the account password
/// is needed, because the device passcode must not unlock the backend session.
struct BiometricService: BiometricAuthenticating {
    func availability() -> BiometricAvailability {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            switch context.biometryType {
            case .faceID: return .available(.faceID)
            case .touchID: return .available(.touchID)
            case .opticID: return .available(.opticID)
            default: return .available(.none)
            }
        }
        switch (error as? LAError)?.code {
        case .biometryNotEnrolled: return .notEnrolled
        case .biometryLockout: return .lockedOut
        default: return .notAvailable
        }
    }

    func authenticate(reason: String) async -> BiometricResult {
        let context = LAContext()
        context.localizedFallbackTitle = ""     // hide "Enter Password": we do not offer a device-passcode bypass
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            switch (error as? LAError)?.code {
            case .biometryLockout: return .lockedOut
            case .biometryNotEnrolled: return .unavailable(.notEnrolled)
            default: return .unavailable(.notAvailable)
            }
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return ok ? .success : .failed
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .systemCancel, .appCancel: return .cancelled
            case .biometryLockout: return .lockedOut
            case .authenticationFailed: return .failed
            case .biometryNotEnrolled: return .unavailable(.notEnrolled)
            default: return .unavailable(.notAvailable)
            }
        } catch { return .failed }
    }
}
