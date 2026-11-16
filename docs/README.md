# Documents

One line each: what it is, and when to read it. For users, start with the
[README](../README.md); for work on the code, with [CLAUDE.md](../CLAUDE.md).

| Document | What it is | Read it when |
|---|---|---|
| [../README.md](../README.md) | User guide: build, install, the `marko` command, shortcuts, behaviour, security summary, troubleshooting | You want to use Marko |
| [../CLAUDE.md](../CLAUDE.md) | The short rules for working here: commands, invariants, isolation of test and smoke runs | At the start of any work on the repository |
| [architecture.md](architecture.md) | How the code works: data flow, invariants, tables, windows, the socket protocol, trust, platform behaviour relied on, `MARKO_*` variables | Before changing the editor, windows, the tool or safe mode |
| [development.md](development.md) | Commands with timings and test counts, running one test, test rules, where a change goes, running the app beside a Marko that is in use, snapshots, driven copies and their cleanup | Before running or writing tests, smoke or a driven run |
| [security.md](security.md) | Safe mode and folder trust in full: what is blocked, what trust allows, what Marko never does | You change anything that fetches, opens or trusts; or you want to know what a prompt means |
| [known-limits.md](known-limits.md) | Every known limit and the detailed editing rules for lists and code | A behaviour looks wrong and may be a known limit; you fix or add one |
| [../THIRD-PARTY-NOTICES.txt](../THIRD-PARTY-NOTICES.txt) | Licences of swift-markdown and swift-cmark; copied into the app | The dependency changes |
| [../LICENSE](../LICENSE) | Marko's own licence (MIT) | |

These documents describe the code as it is. Where one of them and the code disagree, the code is
right and the document is to be corrected.
