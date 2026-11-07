#!/usr/bin/env python3
"""Checks a Quartus build of the core (spec 9.8): python -B scripts/check_build.py <build dir>

Passes when compile.log reports a successful full compilation with 0 errors and no critical
warning, all five worst-case slacks (setup, hold, recovery, removal, minimum pulse width) are
non-negative in every corner, and output_files/ap_core.rbf exists.
"""
import os
import re
import sys


def main():
    build = sys.argv[1] if len(sys.argv) > 1 else os.path.join('build', 'quartus')
    log = os.path.join(build, 'compile.log')
    with open(log, encoding='utf-8', errors='replace') as f:
        text = f.read()
    errors = []
    if 'Full Compilation was successful. 0 errors' not in text:
        errors.append('the full compilation did not succeed with 0 errors')
    if re.search(r'^\s*Critical Warning', text, re.M):
        errors.append('critical warnings remain')
    slacks = {}
    for kind, value in re.findall(r'Worst-case (setup|hold|recovery|removal|minimum pulse width) slack is ([-\d.]+)', text):
        slacks.setdefault(kind, []).append(float(value))
    # the POC rule: each of the five kinds is reported for all 4 corners, none negative
    if len(slacks) != 5 or any(len(v) != 4 or min(v) < 0 for v in slacks.values()):
        errors.append('timing not met in every corner: %s' % slacks)
    if not os.path.exists(os.path.join(build, 'output_files', 'ap_core.rbf')):
        errors.append('output_files/ap_core.rbf missing')
    if errors:
        for e in errors:
            print('ERROR: %s' % e)
        return 1
    print('PASS build: 0 errors, no critical warning, slacks %s' % {k: min(v) for k, v in slacks.items()})
    return 0


if __name__ == '__main__':
    sys.exit(main())