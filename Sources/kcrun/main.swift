import Darwin
import Foundation
import Security

struct EnvironmentMapping {
    let name: String
    let service: String
}

func fail(_ message: String, status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("kcrun: \(message)\n".utf8))
    exit(status)
}

func usageError(_ message: String) -> Never {
    fail("\(message)\nRun 'kcrun --help' for usage.")
}

func showHelp() -> Never {
    let help = """
    Usage:
      kcrun --env NAME=SERVICE [--env NAME=SERVICE ...] -- COMMAND [ARGS...]
      kcrun completions zsh|bash
      kcrun --help

    Read generic passwords from the macOS Keychain, set them as environment
    variables, and replace kcrun with the requested command.

    Options:
      --env NAME=SERVICE  Set NAME to the Keychain generic password for SERVICE.
                          Repeat to provide multiple variables.
      -h, --help          Show this help.
      completions SHELL  Print shell completion code for zsh or Bash.

    Examples:
      kcrun --env API_KEY=my-api-key -- my-tool --option value
      kcrun --env API_KEY=service-one --env TOKEN=service-two -- my-tool

    Store a secret without putting its value in shell history:
      security add-generic-password -a "$USER" -s my-api-key -w

    The command starts only after every requested Keychain item has been read.
    Secret values are not printed by kcrun.
    """
    FileHandle.standardOutput.write(Data((help + "\n").utf8))
    exit(0)
}

func showCompletions(for shell: String) -> Never {
    let script: String
    switch shell {
    case "zsh":
        script = #"""
        _kcrun() {
          if (( ${words[(I)--]} )); then
            _normal
            return
          fi

          _arguments -s \
            '(-h --help)'{-h,--help}'[Show help]' \
            '--env[Set an environment variable from a Keychain service]:NAME=SERVICE:' \
            '--[Start the command and its arguments]'
        }

        compdef _kcrun kcrun
        """#
    case "bash":
        script = #"""
        _kcrun_complete() {
          local cur prev i separator_index=-1
          cur=${COMP_WORDS[COMP_CWORD]}
          prev=${COMP_WORDS[COMP_CWORD-1]}

          for ((i = 1; i < COMP_CWORD; i++)); do
            if [[ ${COMP_WORDS[i]} == -- ]]; then
              separator_index=$i
              break
            fi
          done

          if (( separator_index >= 0 )); then
            if (( COMP_CWORD == separator_index + 1 )); then
              COMPREPLY=( $(compgen -c -- "$cur") )
            fi
            return 0
          fi

          if [[ $prev == --env ]]; then
            compopt +o bashdefault +o default
            return 0
          fi

          COMPREPLY=( $(compgen -W "--env --help -h -- completions" -- "$cur") )
        }

        complete -o bashdefault -o default -F _kcrun_complete kcrun
        """#
    default:
        usageError("unsupported completion shell '\(shell)'; choose 'zsh' or 'bash'")
    }
    FileHandle.standardOutput.write(Data(script.utf8))
    exit(0)
}

func keychainHint(for status: OSStatus) -> String {
    switch status {
    case errSecInteractionNotAllowed:
        return "The Keychain may be locked or macOS may need permission to let kcrun read this item. Unlock the Keychain in Keychain Access and approve access if prompted."
    case errSecAuthFailed:
        return "Keychain access was denied. Check the item's access controls in Keychain Access and allow kcrun to read it."
    case errSecUserCanceled:
        return "Keychain access was cancelled. Retry and approve the access request if prompted."
    case errSecNoSuchKeychain:
        return "The item may be in a Keychain that is not in the user's Keychain search list. Check its location in Keychain Access."
    case errSecNotAvailable:
        return "Keychain services are unavailable. Confirm this is a macOS session with Keychain access."
    default:
        return "Check that the Keychain is available and that kcrun is allowed to read the item."
    }
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
            fail("no generic password found for Keychain service '\(service)'. Add the item in Keychain Access or with 'security add-generic-password'.")
        }
        let systemMessage = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        fail("could not read Keychain service '\(service)': \(systemMessage). \(keychainHint(for: status))")
    }

    guard let data = result as? Data else {
        fail("Keychain returned no password data for service '\(service)'. Check that it is a generic password item.")
    }
    guard let secret = String(data: data, encoding: .utf8) else {
        fail("Keychain value for service '\(service)' is not valid UTF-8. Store the secret as UTF-8 text.")
    }
    return secret
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "completions" {
    guard arguments.count == 2 else {
        usageError("'completions' requires one shell name: zsh or bash")
    }
    showCompletions(for: arguments[1])
}

var mappings: [EnvironmentMapping] = []
var environmentNames = Set<String>()
var index = 0

while index < arguments.count {
    let argument = arguments[index]
    if argument == "--" {
        index += 1
        break
    }
    if argument == "--help" || argument == "-h" {
        showHelp()
    }
    guard argument == "--env" else {
        usageError("unexpected option or argument '\(argument)'")
    }
    index += 1
    guard index < arguments.count, arguments[index] != "--" else {
        usageError("--env requires a NAME=SERVICE mapping")
    }
    let pair = arguments[index]
    guard let separator = pair.firstIndex(of: "=") else {
        usageError("invalid mapping '\(pair)'; expected NAME=SERVICE")
    }
    let name = String(pair[..<separator])
    let service = String(pair[pair.index(after: separator)...])
    guard !name.isEmpty, name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
        usageError("invalid environment-variable name '\(name)'")
    }
    guard !service.isEmpty else {
        usageError("Keychain service name for '\(name)' must not be empty")
    }
    guard environmentNames.insert(name).inserted else {
        usageError("environment variable '\(name)' was specified more than once")
    }
    mappings.append(EnvironmentMapping(name: name, service: service))
    index += 1
}

guard index < arguments.count else {
    usageError("no command provided after '--'")
}
guard !mappings.isEmpty else {
    usageError("at least one --env NAME=SERVICE mapping is required")
}

// Resolve every item before changing the environment or starting the child.
let resolved = mappings.map { ($0.name, readSecret(service: $0.service)) }
for (name, value) in resolved {
    guard setenv(name, value, 1) == 0 else {
        let reason = String(cString: strerror(errno))
        fail("could not set environment variable '\(name)': \(reason) (errno \(errno))")
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

let executionError = errno
let reason = String(cString: strerror(executionError))
if executionError == ENOENT {
    fail("command '\(executable)' was not found. Check its path or make sure it is available in PATH.", status: 127)
}
if executionError == EACCES {
    fail("permission denied when starting '\(executable)'. Check the path and executable permissions.", status: 126)
}
fail("could not start '\(executable)': \(reason) (errno \(executionError))", status: 126)
