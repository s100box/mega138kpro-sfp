<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->
# mega138kpro-sfp: agent and contributor guide

Humans and agents use the same documentation; read it before making changes:

- [README.md](README.md): what the repository holds, the tools and sibling
  repositories it needs, how to build and load it, and the checks.
- [doc/mega138kpro-sfp-design.md](doc/mega138kpro-sfp-design.md): how the
  design works, its registers, the SerDes configuration, and how it is
  verified.

The module, port and parameter names in `rtl/` and the register map in
`rtl/m138_peer.sv` are what the host tool in hh-xcku5p-dev
(`tools/ku5p/m138peer.py`) talks to: change them together with it.

Run `sim/lint.sh` and `sim/gate.sh` before committing; the pre-commit hook
(`git config core.hooksPath .githooks`) runs both.
