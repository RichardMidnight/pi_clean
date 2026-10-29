#!/bin/bash
# NOTE (2026-10-28): the old sed-rebase harness here is obsolete —
# sec_kernels() is now BASE-driven (paths via "${BASE}/boot") and the keep
# rule is strict version equality (the 6.12.15 vs 6.12.150 prefix trap is
# no longer guarded by "ver+*" matching). The current tests live in
# /tmp/pi_clean_test/test_base_sections.sh:
#   * BASE-mode: newest-by-mtime kept, older versions offered
#     (fixture /tmp/pi_clean_test/base_fix: 6.18.50 kept, 6.12.47 offered)
#   * BASE-mode trap: running 6.12.15 must NOT hold back 6.12.150-amd64
#     (fixture /tmp/pi_clean_test/kern_trap, newest-mtime on 6.12.15)
#   * live-mode A/B against this box's real /boot (6.12.75 / 6.18.39 / 6.18.50,
#     +variant board flavors), with uname stubbed
exec bash "$(cd "$(dirname "$0")" && pwd)/test_base_sections.sh"
