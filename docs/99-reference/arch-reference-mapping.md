# Arch Reference Mapping

This project can borrow structure from Arch plugin packaging patterns without copying all complexity.

## Reusable patterns

- one plugin per package
- explicit plugin version and dependency metadata
- post-install usage hints
- optional source package for patching and audit

## Adaptations for Termux

- final runtime verification must happen on Termux
- avoid hidden runtime network installs during plugin load
- keep package scripts simple and reproducible
