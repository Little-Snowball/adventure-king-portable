"""Apply the AS3 patch to a copy of the original gameload.swf with FFDec 26.5.0."""

import argparse
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory


PACKAGE = '§4399load_fla§'

# 新入口必须存在。任一缺失说明 scripts 目录不是这一版启动器源码。
REQUIRED_TIMELINE = ('[AdventureKing]', 'function enterGame()', 'function applyMaxLevel(',
                     'function unlockAllLevels(', 'function dropPetBoards(')
REQUIRED_LOADING = ('function load_inf(', 'function loadFailed(')

# 自绘选单与预设存档已整体移除，导出里再出现即为残留。
FORBIDDEN = ('showStartupMenu', 'startupMenu', 'presetStorage', 'presetLoader',
             'openPreset', 'onPresetClick', 'mountPreset', 'single-mage',
             'double-mage', 'shengbingchuanqi-')


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
        for entry in REQUIRED_TIMELINE:
            if entry not in timeline:
                raise RuntimeError('MainTimeline is missing ' + entry)
        for entry in REQUIRED_LOADING:
            if entry not in loading:
                raise RuntimeError('mc_load_3 is missing ' + entry)
        for name in FORBIDDEN:
            if name in timeline or name in loading:
                raise RuntimeError('Removed startup menu or preset symbol still present: ' + name)
        patched.replace(output)
    print(output)


if __name__ == '__main__':
    main()
