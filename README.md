# kcrun

`kcrun` reads secrets from the macOS Keychain, sets them as environment variables, and starts a command with those variables available. It is a small Swift command-line tool with no third-party dependencies.

## Use kcrun

Save each secret as a generic password in Keychain. The service name identifies the item when you run `kcrun`:

```sh
security add-generic-password -a "$USER" -s example-mcp-api-key1 -w
security add-generic-password -a "$USER" -s example-mcp-api-key2 -w
```

With no value after `-w`, `security` prompts for the secret instead of putting it in shell history. Give each item a unique service name; `kcrun` selects the first generic-password item matching that name.

Pass one or more environment-variable mappings, then `--`, then the command to run:

```sh
kcrun \
  --env MCP_API_KEY1=example-mcp-api-key1 \
  --env MCP_API_KEY2=example-mcp-api-key2 \
  -- my-tool --option value
```

`NAME` must be a valid environment-variable name. Existing environment variables are inherited, and values loaded from Keychain override matching names. The command and its arguments follow `--`.

## Secure an MCP server configuration

Codex can start a local stdio MCP server from `~/.codex/config.toml`. If the server needs a secret, a direct configuration may put its value in the file's `env` table:

```toml
[mcp_servers.example]
command = "/absolute/path/to/example-mcp-server"
args = ["--stdio"]
env = {
  MCP_API_KEY1 = "DANGEROUS_HARDCODED_SECRET_1",
  MCP_API_KEY2 = "DANGEROUS_HARDCODED_SECRET_2",
}
```

This is convenient, but the secret is stored in plain text in the Codex configuration file. To move it to macOS Keychain, save it as a generic password. Use the same account name used by `kcrun` (normally `$USER`):

```sh
security add-generic-password -a "$USER" -s example-mcp-api-key1 -w
security add-generic-password -a "$USER" -s example-mcp-api-key2 -w
```

With no value after `-w`, `security` prompts for the secret. Then replace the MCP entry's `command` and `args` with the following, removing the old `env` table:

```toml
[mcp_servers.example]
command = "/absolute/path/to/kcrun"
args = [
  "--env",
  "MCP_API_KEY1=example-mcp-api-key1",
  "--env",
  "MCP_API_KEY2=example-mcp-api-key2",
  "--",
  "/absolute/path/to/example-mcp-server",
  "--stdio",
]
```

Keep the server's existing arguments after `--`, and replace `/absolute/path/to/...` with the paths on your Mac. The left side of the `--env` mapping is the variable name the server expects; the right side is the Keychain service name. Codex starts `kcrun`, which reads the secret and starts the MCP server with both `MCP_API_KEY1` and `MCP_API_KEY2` set. The secret value is no longer stored in `~/.codex/config.toml`.

See the [Codex configuration reference](https://developers.openai.com/codex/config-reference/) for local MCP server settings.

## What kcrun does

`kcrun` reads every requested Keychain item before starting the command. If a mapping is invalid, a value cannot be read, or a Keychain item is missing, the command is not started. Secret values are not printed; diagnostics go to stderr, and stdout is left for the command. `kcrun` replaces itself with the command, so the command's exit status is returned directly.

## Security considerations

### What this helps protect against

Credentials can end up in local project files and tool settings. Examples include `.env` files; Codex's `~/.codex/config.toml` when an MCP server's `env` table contains secret values; and shell history when credentials are typed directly into commands. The AWS CLI stores access keys in the plaintext `~/.aws/credentials` file by default. SSH private keys are also often kept as files under `~/.ssh`. [Codex configuration reference](https://developers.openai.com/codex/config-reference/), [AWS shared config and credentials files](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html), [MITRE ATT&CK: credentials in files](https://attack.mitre.org/techniques/T1552/001/), [shell history](https://attack.mitre.org/techniques/T1552/003/), and [private keys](https://attack.mitre.org/techniques/T1552/004/).

Keeping a secret in Keychain and supplying it only when starting a command can reduce its exposure to bulk collection of project and configuration files. The secret value is not included in `kcrun`'s command-line arguments or written by `kcrun` to a configuration file.

### What this does not protect against

This is a way to reduce where secrets are stored; it does not make a compromised Mac safe. Information stealers commonly target saved browser credentials, cookies, and other session data. Although browser password databases may be encrypted, malware running as the logged-in user can sometimes extract credentials from them. Attackers also target local credential files, private keys, shell history, and macOS Keychain itself. [MITRE ATT&CK: browser credentials](https://attack.mitre.org/techniques/T1555/003/), [Keychain](https://attack.mitre.org/techniques/T1555/001/), and the [Australian Cyber Security Centre's information-stealer guidance](https://www.cyber.gov.au/guidance/learn-about-information-stealer-malware).

The secret must be present in the child process's environment while it runs. The child and its descendants can read it, and software with sufficient access may inspect process environments. A child can also log or transmit the value. Keychain access controls, a secure macOS account, and trust in the command being launched remain essential.

## Build from source

You need Swift Command Line Tools; the full Xcode application is not required. From the repository root, run:

```sh
swiftc -O -framework Security Sources/kcrun/main.swift -o kcrun
```

The resulting `kcrun` executable is created in the current directory.

## Automated builds and tests

GitHub Actions builds and tests the project on macOS for pushes, pull requests, and manual runs. A successful run uploads the executable and its SHA-256 checksum as a workflow artifact. Open the run in the repository's **Actions** tab and download its artifact. Artifacts are named with the runner architecture and commit, and are retained for 30 days. The current artifacts are not signed or notarized.

Run the integration tests locally on macOS after building:

```sh
Tests/integration.sh ./kcrun
```

The tests create Keychain items containing dummy values, check multiple environment mappings, verify stdout and child exit status, and confirm that a missing item does not start the command. The temporary items are deleted when the tests finish.

## License

MIT. See [LICENSE](LICENSE).
