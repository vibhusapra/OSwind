import Foundation
import Security
import LocalAuthentication
import CryptoKit

/// Implementations must never silently downgrade user-presence protection.
/// Retrieval happens only after an explicit Unlock action, never at startup.
public protocol VaultSecretProvider:Sendable {
    func save(_ passphrase:Data,vaultID:String) throws
    func load(vaultID:String) throws -> Data
    func remove(vaultID:String) throws
}
public struct UserPresenceVaultSecrets:VaultSecretProvider {
    public init() {}
    public static var unavailabilityReason:String? {
        guard let task=SecTaskCreateFromSelf(nil),let id=SecTaskCopyValueForEntitlement(task,"com.apple.application-identifier" as CFString,nil) as? String,!id.isEmpty else {return "This build has no app-identifier entitlement for protected Keychain access. Use the vault passphrase."}
        return nil
    }
    private func query(_ id:String) throws -> [String:Any] {
        guard UUID(uuidString:id)?.uuidString.lowercased()==id else {throw OSwindError.invalid("Invalid vault credential identity")}
        if let reason=Self.unavailabilityReason {throw OSwindError.unavailable(reason)}
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.oswind.vault-passphrases",kSecAttrAccount as String:id,kSecUseDataProtectionKeychain as String:true]
    }
    public func save(_ passphrase:Data,vaultID:String) throws {
        guard !SessionState.locked else {throw OSwindError.unavailable("Unlock your Mac before saving a vault passphrase in Keychain")}
        guard (12...4096).contains(passphrase.count),!passphrase.contains(0),String(data:passphrase,encoding:.utf8) != nil else {throw OSwindError.invalid("Invalid vault passphrase")}
        var error:Unmanaged<CFError>?
        guard let access=SecAccessControlCreateWithFlags(nil,kSecAttrAccessibleWhenUnlockedThisDeviceOnly,.userPresence,&error) else {throw OSwindError.unavailable("Cannot create user-presence Keychain protection")}
        var item=try query(vaultID);item[kSecAttrAccessControl as String]=access;item[kSecValueData as String]=passphrase;item[kSecAttrLabel as String]="OSwind encrypted library"
        let status=SecItemAdd(item as CFDictionary,nil)
        guard status==errSecSuccess else {throw failure(status,"save")}
    }
    public func load(vaultID:String) throws -> Data {
        guard !SessionState.locked else {throw OSwindError.unavailable("Unlock your Mac before authenticating for this vault")}
        let context=LAContext();context.localizedReason="Unlock your OSwind encrypted library";context.touchIDAuthenticationAllowableReuseDuration=0
        var item=try query(vaultID);item[kSecReturnData as String]=true;item[kSecMatchLimit as String]=kSecMatchLimitOne;item[kSecUseAuthenticationContext as String]=context
        var result:CFTypeRef?;let status=SecItemCopyMatching(item as CFDictionary,&result);defer {context.invalidate()}
        guard status==errSecSuccess,let value=result as? Data else {throw failure(status,"unlock")};return value
    }
    public func remove(vaultID:String) throws {
        var item=try query(vaultID);item[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail
        let status=SecItemDelete(item as CFDictionary);guard status==errSecSuccess || status==errSecItemNotFound else {throw failure(status,"remove")}
    }
    private func failure(_ status:OSStatus,_ action:String) -> OSwindError {
        if status==errSecUserCanceled || status==errSecAuthFailed {return .unavailable("Authentication was cancelled or declined. Use your vault passphrase to unlock.")}
        if status==errSecDuplicateItem {return .unavailable("This vault already has a Keychain credential. Forget it before saving another.")}
        return .unavailable("Keychain could not \(action) this vault credential (\(status)). Your passphrase still unlocks the vault.")
    }
}
extension LibraryVault {
    public func rememberPassphrase(_ passphrase:Data,using provider:any VaultSecretProvider=UserPresenceVaultSecrets()) async throws {
        try Self.validateSecret(passphrase)
        let lease=try VaultOperationLease(paths:paths);defer {withExtendedLifetime(lease){}}
        var info=try paths.info()
        guard info.setupComplete,try VaultAccess.context(at:libraryURL) != nil else {throw OSwindError.unavailable("Unlock the vault before saving its passphrase in Keychain")}
        guard acceptedPassphraseDigest==Data(SHA256.hash(data:passphrase)) else {throw OSwindError.unavailable("Lock this vault, then unlock it with the passphrase before remembering it in Keychain")}
        try provider.save(passphrase,vaultID:info.id)
        info.keychainEnabled=true
        do {try paths.write(info,as:VaultPaths.manifestName)} catch {try? provider.remove(vaultID:info.id);throw error}
    }
    public func forgetPassphrase(using provider:any VaultSecretProvider=UserPresenceVaultSecrets()) throws {
        let lease=try VaultOperationLease(paths:paths);defer {withExtendedLifetime(lease){}}
        var info=try paths.info();try provider.remove(vaultID:info.id);info.keychainEnabled=false;try paths.write(info,as:VaultPaths.manifestName)
    }
    public func unlockUsingKeychain(using provider:any VaultSecretProvider=UserPresenceVaultSecrets()) async throws -> LibraryVaultStatus {
        let info=try paths.info();guard info.keychainEnabled else {throw OSwindError.unavailable("No Keychain credential was saved for this vault. Use its passphrase.")}
        var passphrase=try provider.load(vaultID:info.id);defer {passphrase.resetBytes(in:0..<passphrase.count)}
        return try await unlock(passphrase:passphrase)
    }
}
