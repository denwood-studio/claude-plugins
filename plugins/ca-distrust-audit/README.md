# ca-distrust-audit

Tells you, without changing anything, whether your Mac or a repo still trusts a distrusted certificate authority chain. It starts with the October 2026 eMudhra intermediate CA compromise.

Unofficial. Not affiliated with eMudhra or Anthropic.

## Install

```
claude plugin marketplace add denwood-studio/claude-plugins
claude plugin install ca-distrust-audit@denwood-studio
```

Then, in a Claude Code session, run `/ca-distrust-audit:audit`. It audits this Mac and the project you are in, and reads the report back to you.

You can also run the script yourself. It needs bash 3.2 or later, POSIX awk, grep, find, xargs and openssl, plus `sw_vers` and `plutil` on macOS.

```
plugins/ca-distrust-audit/scripts/audit.sh machine
plugins/ca-distrust-audit/scripts/audit.sh repo <dir>
```

It exits 0 whenever the audit completes, whatever the verdict. It exits 2 on a usage error, a missing directory, no data files, or `machine` on anything other than macOS.

## What each mode checks

**`machine`** (macOS only)

- The macOS version, from `sw_vers -productVersion`.
- Every Node.js install: each `node` on your `PATH`, plus the install directories of nvm, mise, asdf, fnm, Volta, nodenv, n and Homebrew. Shim directories are skipped. Each install is resolved to its real path, deduplicated, and asked for its version by running that exact path under `env -i`.
- Every Electron app directly inside `/Applications` or `~/Applications`. The Electron version is read from the app's `Electron Framework.framework`. An Electron app keeps the trust store of the Electron release it was built on, so updating the OS does not fix it.

**`repo <dir>`**

- Dockerfiles and Containerfiles (`Dockerfile`, `Dockerfile.*`, `*.Dockerfile`, `*.dockerfile`, `Containerfile`, `Containerfile.*`), anywhere outside `.git` and `node_modules`. Each file is split into stages at `FROM`. A stage is CLEAR only when it proves a fixed `ca-certificates`: a `dpkg --compare-versions ... ca-certificates ... ge|gt|eq <version>` check, an `apt` or `apt-get` pin `ca-certificates=<version>`, or an `apk` pin `ca-certificates=<version>` or `>=<version>`, with a version that is fixed. A stage inherits the best status of its parent stages. A file takes its worst stage. Stages built `FROM scratch` are not assessed.
- PEM certificate bundles: every text file outside `.git`, including inside `node_modules`, vendor directories and virtualenvs, that contains `-----BEGIN CERTIFICATE-----`. Each certificate is fingerprinted (SHA-256 of the DER bytes) and compared with the certificates in the data file. Copies bundled inside dependencies are the usual hidden exposure.

## FLAG, UNCONFIRMED and CLEAR

| Line | Meaning |
| --- | --- |
| `FLAG` | The audit found something that still trusts the chain, or is older than the fixed version. The line says what to move to. |
| `UNCONFIRMED` | The audit cannot prove it either way, and the line says how you can confirm it yourself. Example: a Dockerfile installs `ca-certificates` but never asserts a version. Nothing fails the build on an old store, and a cached layer keeps the old one. |
| `CLEAR` | The audit found proof the item is fixed, or found nothing wrong with it. |

The last line is `Verdict: FLAGGED`, `UNCONFIRMED` or `CLEAR`: the worst of the lines above it. A CLEAR verdict covers only what was checked. Read the Not checked line.

## Every report names its date

Each report has one `Checked against:` line per data file, before that file's findings:

```
Checked against: <event> — fixed-version list as of <date> (<first source>)
```

The date is the day the fixed versions in that data file were last read from its sources. Fixed versions keep changing as vendors ship patches, so a report is only as current as that date.

## Read-only guarantee

The audit audits and reports. It never patches, installs, edits or deletes anything, and `/ca-distrust-audit:audit` never applies a fix, even if you ask. The fix is given as text for you to run.

How the script enforces it:

- It writes nothing anywhere. The only redirection to a file is `/dev/null`. It uses no temporary files, no heredocs and no here-strings (bash 3.2 backs both with temp files), and it never changes into the audited tree.
- It makes no network connection.
- It runs no package manager, docker, git or version-manager command.
- It runs an executable only by its resolved absolute path, under `env -i`. It never runs `node` by name: a mise or asdf shim can install the Node version a project asks for, and mise does so by default.
- It treats repo text as untrusted. Report lines name paths and image names that are stripped to printable ASCII, and never print file contents.

The tests check this: a fixture repo has the same file stat manifest and `git status` before and after a run, and on macOS both modes are run under `sandbox-exec` with all file writes denied and must print the same output with an empty stderr.

## Not checked

`machine`:

- Homebrew, Python, pip and certifi stores
- Java keystores
- Go and Rust binaries
- Docker Desktop and images
- browsers
- apps outside `/Applications` and `~/Applications`
- apps that patch their own store

`repo`:

- lockfiles and version pins
- images pulled by name (compose files, CI)
- runtimes inside images
- binary keystores (`.jks`, `.p12`, `.pfx`, `.der`, `.p7b`, `cacerts`); the report counts them
- the live TLS behaviour of built images

## Add a new CA event

A new event needs only a new data file in `data/`. No script or skill change. The script audits against every `data/*.tsv` file and prints one `Checked against` line for each.

A data file is tab-separated. Lines starting with `#` are comments.

| Line | Fields |
| --- | --- |
| `event` | `<one-line title>` |
| `as-of` | `<YYYY-MM-DD>`, the day the facts were read. Exactly one. |
| `source` | `<url>`. At least one. The first is shown in the report. |
| `cert` | `<SHA-256 of the DER certificate, 64 uppercase hex>` and `<label>` |
| `fixed` | `<component>` and `<version>` |
| `line` | `<component>` and `<POSIX ERE>`. Optional. The default is `^[0-9]+`. |

The script reads these components and ignores any other: `macos`, `node`, `electron`, `dpkg:ca-certificates` and `apk:ca-certificates`. An event that lists no `fixed` lines for a component, or no `cert` lines, is simply not checked for it.

A `line` is a release line, such as the Node major version. A version is fixed when a fixed version on its own line is at or below it. If no fixed version shares its line, it is fixed only when it is at or above every fixed version. The version to move to is the fixed version on its line, or else the smallest fixed version above it. Versions are ordered the way dpkg orders them: `~` sorts before everything, digit runs compare as numbers, and a leading `v` is ignored.

Copy a certificate fingerprint from the disclosure for the event, or compute it yourself:

```
openssl x509 -in cert.pem -outform DER | openssl dgst -sha256
```

`tests/ca-distrust-audit/test-data.sh` lints every data file.

## Sources and test hosts

- https://emudhra.we-have-a-problem.com/ : the disclosure site. Its "Who has patched?" table, `impacted-intermediates.json` and `roots.json` feed `data/emudhra-2026-10.tsv`.
- https://www.endorlabs.com/learn/emudhra-intermediate-ca-compromise-the-trust-stores-you-patched-and-the-ones-you-didnt-know-you-had : the Endor Labs write-up of which trust stores were and were not patched.

The disclosure site also runs test hosts that serve a certificate chain issued by a compromised intermediate. Run a client against one:

```
curl https://dv-g3b-emudhra.we-have-a-problem.com/
curl https://dv-g3b-aaa-emudhra.we-have-a-problem.com/
```

A certificate error means the client does not trust the compromised intermediates. A successful connection means it still does. The `noct` hosts (for example `https://dv-g3b-noct-emudhra.we-have-a-problem.com/`) use leaf certificates that were never logged to Certificate Transparency, so they also show whether the client enforces Certificate Transparency.

Use a test host to check a client the audit cannot see.
