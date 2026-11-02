import Foundation
import Security

enum SyncCredentialStorageLimits {
    static let maximumBytes=131072
    static func validate(id:String,bytes:Data?=nil)throws {
        try SyncProtocolLimits.uuid(id)
        if let bytes {guard !bytes.isEmpty,bytes.count<=maximumBytes else {throw SyncCredentialStorageError.invalid}}
    }
}
enum SyncCredentialProtection:String,Codable,Sendable {
    // The file-based implementation makes no ThisDeviceOnly/hardware claim.
    case loginKeychain,dataProtectionKeychain
}
enum SyncCredentialStorageError:Error,Equatable {
    case invalid,missing,alreadyExists,changed,unavailable(Int32)
}

/// Mutations require the enrollment owner's cross-process credential lease.
/// The expected bytes prevent replacement/deletion of a different saved state;
/// they do not turn Security.framework and SQLite into one transaction.
protocol SyncCredentialStorage:Sendable {
    var protection:SyncCredentialProtection {get}
    func create(id:String,bytes:Data)throws
    func read(id:String)throws->Data
    func replace(id:String,expected:Data,bytes:Data)throws
    func remove(id:String,expected:Data)throws
}

/// Separate namespace from model providers, MCP tools and vault passphrases.
/// Never enumerate a user's Keychain, silently recreate missing credentials or
/// switch an enrolled protection tier. All requests refuse authentication UI.
struct SyncKeychainCredentialStorage:SyncCredentialStorage,Sendable {
    static let service="com.oswind.personal-sync.credentials.v1"
    let protection:SyncCredentialProtection
    init(protection:SyncCredentialProtection) {self.protection=protection}
    private func query(_ id:String)throws->[String:Any] {
        try SyncCredentialStorageLimits.validate(id:id)
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:Self.service,kSecAttrAccount as String:id,
                kSecUseDataProtectionKeychain as String:protection == .dataProtectionKeychain,
                kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
    }
    func create(id:String,bytes:Data)throws {
        try SyncCredentialStorageLimits.validate(id:id,bytes:bytes)
        var value=try query(id);value[kSecValueData as String]=bytes;value[kSecAttrLabel as String]="OSwind personal device sync"
        if protection == .dataProtectionKeychain {
            value[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            value[kSecAttrSynchronizable as String]=false
        }
        let result=SecItemAdd(value as CFDictionary,nil)
        guard result==errSecSuccess else {throw failure(result)}
    }
    func read(id:String)throws->Data {
        var value=try query(id);value[kSecReturnData as String]=true;value[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(value as CFDictionary,&result)
        guard status==errSecSuccess else {throw failure(status)}
        guard let bytes=result as? Data else {throw SyncCredentialStorageError.invalid}
        try SyncCredentialStorageLimits.validate(id:id,bytes:bytes);return bytes
    }
    func replace(id:String,expected:Data,bytes:Data)throws {
        try SyncCredentialStorageLimits.validate(id:id,bytes:expected);try SyncCredentialStorageLimits.validate(id:id,bytes:bytes)
        guard try read(id:id)==expected else {throw SyncCredentialStorageError.changed}
        let status=SecItemUpdate(try query(id) as CFDictionary,[kSecValueData as String:bytes] as CFDictionary)
        guard status==errSecSuccess else {throw failure(status)}
    }
    func remove(id:String,expected:Data)throws {
        try SyncCredentialStorageLimits.validate(id:id,bytes:expected)
        guard try read(id:id)==expected else {throw SyncCredentialStorageError.changed}
        let status=SecItemDelete(try query(id) as CFDictionary)
        guard status==errSecSuccess else {throw failure(status)}
    }
    private func failure(_ status:OSStatus)->SyncCredentialStorageError {
        switch status {
        case errSecItemNotFound:return .missing
        case errSecDuplicateItem:return .alreadyExists
        default:return .unavailable(status)
        }
    }
}
