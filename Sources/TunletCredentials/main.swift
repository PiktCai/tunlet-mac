import Darwin
import Foundation
import LocalAuthentication
import Security

private let credentialService = "io.github.piktcai.tunlet.credentials"

private enum CredentialMode: String {
    case touchID = "touch-id"
    case automatic
}

private enum ToolError: Error {
    case authenticationFailed(String)
    case invalidArguments(String)
    case keychain(OSStatus)
    case missingCredential
    case missingPassword
}

private struct CredentialTarget {
    let server: String
    let username: String

    var account: String {
        "\(server)\u{001F}\(username)"
    }
}

private struct ParsedArguments {
    let command: String
    let target: CredentialTarget?
    let mode: CredentialMode?

    init(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw ToolError.invalidArguments(Self.usage)
        }

        var server: String?
        var username: String?
        var mode: CredentialMode?
        var index = 1

        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else {
                throw ToolError.invalidArguments("Missing value for \(option).")
            }
            let value = arguments[index + 1]
            switch option {
            case "--server":
                server = value
            case "--username":
                username = value
            case "--mode":
                guard let parsedMode = CredentialMode(rawValue: value) else {
                    throw ToolError.invalidArguments("Mode must be touch-id or automatic.")
                }
                mode = parsedMode
            default:
                throw ToolError.invalidArguments("Unknown option: \(option)")
            }
            index += 2
        }

        self.command = command
        self.mode = mode

        if let server, let username, !server.isEmpty, !username.isEmpty {
            target = CredentialTarget(server: server, username: username)
        } else {
            target = nil
        }
    }

    static let usage = """
    Usage:
      tunlet-credentials read --server <server> --username <username>
      tunlet-credentials save --server <server> --username <username> --mode <touch-id|automatic>
      tunlet-credentials mode --server <server> --username <username>
      tunlet-credentials delete --server <server> --username <username>
      tunlet-credentials delete-all
    """
}

private func keychainMessage(for status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) as String? {
        return message
    }
    return "Keychain error \(status)"
}

private func baseQuery(for target: CredentialTarget) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: credentialService,
        kSecAttrAccount as String: target.account,
    ]
}

private func mode(for target: CredentialTarget) throws -> CredentialMode {
    var query = baseQuery(for: target)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
        throw ToolError.missingCredential
    }
    guard status == errSecSuccess else {
        throw ToolError.keychain(status)
    }
    guard
        let attributes = result as? [String: Any],
        let storedMode = attributes[kSecAttrComment as String] as? String,
        let credentialMode = CredentialMode(rawValue: storedMode)
    else {
        return .touchID
    }
    return credentialMode
}

private func authenticate() async throws {
    let context = LAContext()
    context.localizedCancelTitle = "Enter Password Manually"
    let reason = "Use the aTrust password saved by Tunlet."
    var error: NSError?

    let policy: LAPolicy
    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
        policy = .deviceOwnerAuthenticationWithBiometrics
    } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
        policy = .deviceOwnerAuthentication
    } else {
        throw ToolError.authenticationFailed(
            error?.localizedDescription ?? "System authentication is unavailable."
        )
    }

    do {
        guard try await context.evaluatePolicy(policy, localizedReason: reason) else {
            throw ToolError.authenticationFailed("Authentication was not completed.")
        }
    } catch {
        throw ToolError.authenticationFailed(error.localizedDescription)
    }
}

private func readCredential(for target: CredentialTarget) async throws {
    let credentialMode = try mode(for: target)
    if credentialMode == .touchID {
        try await authenticate()
    }

    var query = baseQuery(for: target)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
        throw ToolError.missingCredential
    }
    guard status == errSecSuccess else {
        throw ToolError.keychain(status)
    }
    guard let password = result as? Data else {
        throw ToolError.keychain(errSecDecode)
    }
    FileHandle.standardOutput.write(password)
}

private func saveCredential(
    for target: CredentialTarget,
    mode credentialMode: CredentialMode
) throws {
    let password = FileHandle.standardInput.readDataToEndOfFile()
    guard !password.isEmpty else {
        throw ToolError.missingPassword
    }

    let query = baseQuery(for: target)
    let values: [String: Any] = [
        kSecValueData as String: password,
        kSecAttrComment as String: credentialMode.rawValue,
        kSecAttrLabel as String: "Tunlet aTrust password",
        kSecAttrDescription as String: "Password stored by Tunlet",
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if updateStatus == errSecSuccess {
        return
    }
    guard updateStatus == errSecItemNotFound else {
        throw ToolError.keychain(updateStatus)
    }

    var addQuery = query
    for (key, value) in values {
        addQuery[key] = value
    }
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
        throw ToolError.keychain(addStatus)
    }
}

private func deleteAllCredentials() throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: credentialService,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ToolError.keychain(status)
    }
}

private func deleteCredential(for target: CredentialTarget) throws {
    let status = SecItemDelete(baseQuery(for: target) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ToolError.keychain(status)
    }
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

@main
private struct TunletCredentials {
    static func main() async {
        do {
            let arguments = try ParsedArguments(Array(CommandLine.arguments.dropFirst()))
            switch arguments.command {
            case "read":
                guard let target = arguments.target else {
                    throw ToolError.invalidArguments("read requires --server and --username.")
                }
                try await readCredential(for: target)
            case "save":
                guard let target = arguments.target, let credentialMode = arguments.mode else {
                    throw ToolError.invalidArguments(
                        "save requires --server, --username, and --mode."
                    )
                }
                try saveCredential(for: target, mode: credentialMode)
            case "mode":
                guard let target = arguments.target else {
                    throw ToolError.invalidArguments("mode requires --server and --username.")
                }
                print(try mode(for: target).rawValue)
            case "delete":
                guard let target = arguments.target else {
                    throw ToolError.invalidArguments("delete requires --server and --username.")
                }
                try deleteCredential(for: target)
            case "delete-all":
                guard arguments.target == nil, arguments.mode == nil else {
                    throw ToolError.invalidArguments("delete-all does not accept options.")
                }
                try deleteAllCredentials()
            case "help", "--help", "-h":
                print(ParsedArguments.usage)
            default:
                throw ToolError.invalidArguments("Unknown command: \(arguments.command)")
            }
        } catch ToolError.missingCredential {
            exit(3)
        } catch ToolError.authenticationFailed(let message) {
            writeError("Authentication failed: \(message)")
            exit(4)
        } catch ToolError.invalidArguments(let message) {
            writeError(message)
            exit(2)
        } catch ToolError.keychain(let status) {
            writeError(keychainMessage(for: status))
            exit(1)
        } catch ToolError.missingPassword {
            writeError("Password input is empty.")
            exit(2)
        } catch {
            writeError(error.localizedDescription)
            exit(1)
        }
    }
}
