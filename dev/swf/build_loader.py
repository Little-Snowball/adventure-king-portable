"""Apply the AS3 patch to a copy of the original gameload.swf with FFDec 26.5.0."""

import argparse
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory


PACKAGE = '§4399load_fla§'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffdec', type=Path, required=True, help='Path to ffdec.jar')
    parser.add_argument('--input', type=Path, required=True, help='Original gameload.swf')
    parser.add_argument('--output', type=Path, required=True, help='Patched gameload.swf')
    args = parser.parse_args()
    original = args.input.resolve(strict=True)
    ffdec = args.ffdec.resolve(strict=True)
    output = args.output.resolve()
    if original == output or output.exists() and original.samefile(output):
        parser.error('Choose an output distinct from the input SWF')

    scripts = Path(__file__).resolve().parent / 'scripts'
    output.parent.mkdir(parents=True, exist_ok=True)
    command = ['java', '-Djava.awt.headless=true', '-jar', str(ffdec)]
    with TemporaryDirectory(dir=output.parent) as work:
        work = Path(work)
        patched = work / 'gameload.swf'
        subprocess.run(command + ['-importScript', str(original), str(patched), str(scripts)], check=True)
        subprocess.run(command + ['-export', 'script', str(work / 'verify'), str(patched)], check=True)
        exported = work / 'verify' / 'scripts' / PACKAGE
        timeline = (exported / 'MainTimeline.as').read_text(encoding='utf-8')
        loading = (exported / 'mc_load_3.as').read_text(encoding='utf-8')
        if ('[AdventureKing]' not in timeline or 'function showStartupMenu()' not in timeline
                or '.readObject()' not in timeline or 'function showStart()' not in loading):
            raise RuntimeError('The exported SWF is missing the startup menu or preset loader patch')
        patched.replace(output)
    print(output)


if __name__ == '__main__':
    main()
