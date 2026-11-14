"""Python entry point; the Tcl runtime remains the command interpreter."""
import os
from pathlib import Path
import sys


def main():
    script = Path(__file__).resolve().parent / 'bin' / 'faultplus'
    try:
        os.execvp('tclsh', ['tclsh', str(script), *sys.argv[1:]])
    except FileNotFoundError:
        print('Fault+ requires tclsh in PATH', file=sys.stderr)
        return 127
