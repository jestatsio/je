import Foundation
import JECore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS)
import Security
#endif

private func respond(_ response: SecretHelperResponse, code: Int32) -> Never {
    if let data = try? StableJSON.encodeLine(response) {
        FileHandle.standardOutput.write(data)
    }
    exit(code)
}

private func fail() -> Never {
    respond(SecretHelperResponse(ok: false), code: 2)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= 16 * 1024,
      let request = try? JSONDecoder().decode(SecretHelperRequest.self, from: input),
      request.schemaVersion == 1,
      SecretReferenceValidator.isValid(request.reference) else {
    fail()
}

#if os(macOS)
private let serviceName = "io.jestats.je"

private func baseQuery(reference: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: reference,
        kSecAttrSynchronizable as String: false
    ]
}

private func setSecret(_ secret: String, reference: String) -> Never {
    guard !secret.isEmpty, secret.count <= 8192, !secret.unicodeScalars.contains(where: { $0.value == 0 }),
          let data = secret.data(using: .utf8) else {
        fail()
    }
    let query = baseQuery(reference: reference)
    let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updateStatus == errSecSuccess {
        respond(SecretHelperResponse(ok: true), code: 0)
    }
    guard updateStatus == errSecItemNotFound else {
        fail()
    }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
        fail()
    }
    respond(SecretHelperResponse(ok: true), code: 0)
}

private func getSecret(reference: String) -> Never {
    var query = baseQuery(reference: reference)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
        respond(SecretHelperResponse(ok: true), code: 0)
    }
    guard status == errSecSuccess,
          let data = result as? Data,
          data.count <= 8192,
          let secret = String(data: data, encoding: .utf8) else {
        fail()
    }
    respond(SecretHelperResponse(ok: true, secret: secret), code: 0)
}

private func deleteSecret(reference: String) -> Never {
    let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        fail()
    }
    respond(SecretHelperResponse(ok: true), code: 0)
}

switch request.operation {
case "set":
    guard let secret = request.secret else { fail() }
    setSecret(secret, reference: request.reference)
case "get":
    guard request.secret == nil else { fail() }
    getSecret(reference: request.reference)
case "delete":
    guard request.secret == nil else { fail() }
    deleteSecret(reference: request.reference)
default:
    fail()
}
#else
fail()
#endif
