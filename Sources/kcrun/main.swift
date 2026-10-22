import Darwin
import Foundation
import Security

struct EnvironmentMapping {
    let name: String
    let service: String
}

func fail(_ message: String, status: Int32 = 2) -> Never {
    let line = "kcrun: \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    exit(status)
}

func readSecret(service: String) -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: service,
        kSecReturnData as String: true
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
        if status == errSecItemNotFound {
            fail("no Keychain item found for service '\(service)'")
        }
        fail("Keychain lookup failed for service '\(service)' (status \(status))")
    }

    guard let data = result as? Data else {
        fail("could not read Keychain value for service '\(service)'")
    }
    guard let secret = String(data: data, encoding: .utf8) else {
        fail("Keychain value for service '\(service)' is not valid UTF-8")
    }
    return secret
}

let arguments = Array(CommandLine.arguments.dropFirst())
var mappings: [EnvironmentMapping] = []
var environmentNames = Set<String>()
var index = 0

while index < arguments.count {
    let argument = arguments[index]
    if argument == "--" {
        index += 1
        break
    }
    guard argument == "--env" else {
        fail("unexpected argument '\(argument)'; use --env NAME=SERVICE and -- COMMAND [ARGS...]")
    }
    index += 1
    guard index < arguments.count else { fail("--env requires NAME=SERVICE") }
    let pair = arguments[index]
    guard let separator = pair.firstIndex(of: "=") else {
        fail("invalid mapping '\(pair)'; expected NAME=SERVICE")
    }
    let name = String(pair[..<separator])
    let service = String(pair[pair.index(after: separator)...])
    guard !name.isEmpty, name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
        fail("invalid environment variable name '\(name)'")
    }
    guard !service.isEmpty else { fail("service name must not be empty") }
    guard environmentNames.insert(name).inserted else {
        fail("environment variable '\(name)' was specified more than once")
    }
    mappings.append(EnvironmentMapping(name: name, service: service))
    index += 1
}

guard index < arguments.count else {
    fail("a command is required after --")
}
guard !mappings.isEmpty else {
    fail("at least one --env NAME=SERVICE mapping is required")
}

// Resolve every item before changing the environment or starting the child.
let resolved = mappings.map { ($0.name, readSecret(service: $0.service)) }
for (name, value) in resolved {
    guard setenv(name, value, 1) == 0 else {
        fail("could not set environment variable '\(name)' (errno \(errno))")
    }
}

let commandAndArguments = Array(arguments[index...])
let executable = commandAndArguments[0]
var argv = commandAndArguments.map { strdup($0) }
argv.append(nil)
defer { for pointer in argv where pointer != nil { free(pointer) } }

_ = executable.withCString { path in
    argv.withUnsafeMutableBufferPointer { buffer in
        execvp(path, buffer.baseAddress!)
    }
}
fail("could not execute '\(executable)' (errno \(errno))", status: 127)
