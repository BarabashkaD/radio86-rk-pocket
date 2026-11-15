#!/usr/bin/env python3
"""Where the libraries of this repo are: the submodules lib/retroMachines (with its own submodule
lib/retroICs) and lib/retro8080Software.

  retro_machines_dir()  the retroMachines checkout: RETRO_MACHINES_DIR (a repo root), default
                        <repo>/lib/retroMachines
  retro_ics_tools()     retroICs' tools/ folder (simrun, check_records) in that checkout:
                        <retroMachines>/lib/retroICs/tools
  rk86_roms()           the Radio-86RK monitor.bin and font.bin: <retroMachines>/machines/rk86/roms
  software_dir()        the retro8080Software checkout: RETRO_SOFTWARE_DIR (a repo root), default
                        <repo>/lib/retro8080Software
  pk_dir()              the game tapes: <retro8080Software>/rk86/collections/pyhonin-1999

A missing or empty submodule raises LayoutError naming it (lib/retroMachines, its nested
lib/retroMachines/lib/retroICs, lib/retro8080Software) and the command that fetches it; with check=False
each gives its path unchecked (a reader that names the missing file then names the override's). A consumer in
another folder loads this file with importlib under the module name MODULE (each the same way, so
they share one module): scripts/k1/layout.py is the module `layout` of the K1 tools, and the tests
run in one process.
"""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FETCH = 'run git submodule update --init --recursive'
MODULE = 'rk86_repo_layout'


class LayoutError(RuntimeError):
    """A submodule is missing or not checked out."""


def _dir(var, default):
    value = os.environ.get(var)
    return Path(value).resolve() if value else (ROOT / default).resolve()


def retro_machines_dir(check=True) -> Path:
    """The retroMachines checkout (RETRO_MACHINES_DIR, default lib/retroMachines), checked: its
    machines/rk86/component.toml and the tools of its lib/retroICs. check=False: the same path
    unchecked (a wrong override stays the override, so the reader's error names its file)."""
    d = _dir('RETRO_MACHINES_DIR', 'lib/retroMachines')
    if check and not (d / 'machines' / 'rk86' / 'component.toml').is_file():
        raise LayoutError('lib/retroMachines missing: %s' % FETCH)
    if check and not (d / 'lib' / 'retroICs' / 'tools' / 'simrun').is_dir():
        # retroMachines checked out without --recursive: its own submodule is empty
        raise LayoutError('lib/retroMachines/lib/retroICs missing: %s' % FETCH)
    return d


def retro_ics_dir(check=True) -> Path:
    """The retroICs checkout inside retroMachines (lib/retroICs)."""
    return retro_machines_dir(check) / 'lib' / 'retroICs'


def retro_ics_tools() -> Path:
    """retroICs' tools/ folder: put it on sys.path for simrun (simrun.negative, simrun.filelist)."""
    return retro_ics_dir() / 'tools'


def search_roots() -> list:
    """simrun's search roots: retroMachines, then its retroICs."""
    return [retro_machines_dir(), retro_ics_dir()]


def rk86_roms(check=True) -> Path:
    """The folder with the Radio-86RK monitor.bin and font.bin."""
    return retro_machines_dir(check) / 'machines' / 'rk86' / 'roms'


def software_dir(check=True) -> Path:
    """The retro8080Software checkout (RETRO_SOFTWARE_DIR, default lib/retro8080Software), checked:
    the game tape collection's DESCRIPT.ION. check=False: the same path unchecked."""
    d = _dir('RETRO_SOFTWARE_DIR', 'lib/retro8080Software')
    if check and not (d / 'rk86' / 'collections' / 'pyhonin-1999' / 'DESCRIPT.ION').is_file():
        raise LayoutError('lib/retro8080Software missing: %s' % FETCH)
    return d


def pk_dir(check=True) -> Path:
    """The game tapes (.GAM, .RKR, DESCRIPT.ION) of the RK86 collection pyhonin-1999."""
    return software_dir(check) / 'rk86' / 'collections' / 'pyhonin-1999'
