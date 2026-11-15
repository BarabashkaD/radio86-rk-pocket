#!/usr/bin/env python3
"""simrun of lib/retroMachines/lib/retroICs from this repo, with the libraries as search roots.

    python -B scripts/simrun.py filelist machines/rk86 --format qsf --relative-to <build dir>
    python -B scripts/simrun.py run machines/rk86 --tier standard [--negative] [--replace FILE=FILES]
        [--param NAME=V] [--out DIR] [--iverilog PATH] [--test NAME ...]

Puts retroICs' tools/ (scripts/layout.py, retro_ics_tools()) on the module path and runs
`python -m simrun` with the arguments given. Without --search the search roots are
lib/retroMachines and lib/retroMachines/lib/retroICs (RETRO_MACHINES_DIR moves both); the
commands, options and exit codes are simrun's (its module docstring). A missing submodule: one
ERROR line naming git submodule update --init --recursive, exit 2.

--test NAME (run only, repeatable; this launcher's, not simrun's): only the named tests of the
components given, with their faults (weekly.yml: one job per test). A name that none of the
components has: one ERROR line, exit 2.
"""
import dataclasses
import os
import sys

sys.dont_write_bytecode = True   # no __pycache__ in the submodules
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import layout  # noqa: E402  (scripts/layout.py: this folder comes first)


def argv_with_search(argv, roots):
    """argv with --search for each root after the command, unless argv already has --search."""
    if not argv or any(a == '--search' or a.startswith('--search=') for a in argv):
        return list(argv)
    return [argv[0]] + [x for r in roots for x in ('--search', str(r))] + list(argv[1:])


def split_tests(argv):
    """(argv without the --test options, the test names); only for the run command."""
    if not argv or argv[0] != 'run':
        return list(argv), []
    out, names, i = [], [], 0
    while i < len(argv):
        a = argv[i]
        if a == '--test':
            if i + 1 >= len(argv) or argv[i + 1].startswith('-'):
                raise ValueError('--test needs a test name')
            names.append(argv[i + 1])
            i += 2
            continue
        if a.startswith('--test='):
            if a == '--test=':
                raise ValueError('--test needs a test name')
            names.append(a[len('--test='):])
        else:
            out.append(a)
        i += 1
    return out, names


def only_tests(components_at, names, error):
    """components_at that keeps only the named tests (and their faults) of each component."""
    def wrapped(args, search):
        comps = components_at(args, search)
        missing = sorted(set(names) - {t.name for c in comps for t in c.tests})
        if missing:
            raise error('--test %s: no such test in %s' % (', '.join(missing), ', '.join(args)))
        return [dataclasses.replace(c, tests=[t for t in c.tests if t.name in names],
                                    negatives=[n for n in c.negatives if n.test in names])
                for c in comps]
    return wrapped


def main(argv=None):
    argv = sys.argv[1:] if argv is None else list(argv)
    try:
        argv, names = split_tests(argv)
    except ValueError as e:
        print('ERROR: %s' % e)
        return 2
    try:
        tools = layout.retro_ics_tools()
        roots = layout.search_roots()
    except layout.LayoutError as e:
        print('ERROR: %s' % e)
        return 2
    sys.path.insert(0, str(tools))
    from simrun import __main__ as simrun_main  # noqa: E402
    if names:
        from simrun import manifest  # noqa: E402
        simrun_main.components_at = only_tests(simrun_main.components_at, names,
                                               manifest.ManifestError)
    return simrun_main.main(argv_with_search(argv, roots))


if __name__ == '__main__':
    sys.exit(main())
