import Foundation
import Security
import OSwindCore

/// This adapter never enumerates or touches model-provider credential accounts.
/// Injection in controller tests avoids real user Keychain operations.
enum MCPKeychainCredentials {
    static func validateAccount(_ account:String)throws {
        let parts=account.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==3,parts[0]=="mcp",UUID(uuidString:String(parts[1]))?.uuidString.lowercased()==String(parts[1]) else {throw OSwindError.invalid("Invalid tool credential account")}
        try MCPServerCommand(executable:"/unused",credentialNames:[String(parts[2])]).validate()
    }
    static func read(_ account:String)->String? {guard (try? validateAccount(account)) != nil else {return nil};return SecretStore.get(account)}
    static func write(_ account:String,_ value:String)throws {
        try validateAccount(account)
        if !value.isEmpty {try SecretStore.set(account,value:value);return}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.oswind.secrets",kSecAttrAccount as String:account]
        try verifyDeletion(SecItemDelete(query as CFDictionary))
    }
    static func verifyDeletion(_ status:OSStatus)throws {
        guard status==errSecSuccess || status==errSecItemNotFound else {throw OSwindError.unavailable("Keychain did not confirm credential removal (\(status)). The connection remains available for retry.")}
    }
}
