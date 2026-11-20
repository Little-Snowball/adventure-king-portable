"""Apply pet and mage resource changes to a copy of game.swf (JPEXS FFDec 26.5.0)."""

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import struct
import subprocess
from tempfile import TemporaryDirectory
import zlib

from resource_patch import patch_resources, reference


PET_CLASSES = {
    'petrole1_1': (10, 'attack2'),
    'petrole1_2': (10, 'attack2'),
    'petrole1_3': (50, 'attack2'),
    'petrole2_1': (10, 'attack2'),
    'petrole2_2': (20, 'attack2'),
    'petrole2_3': (30, 'attack2'),
    'petrole3_1': (20, 'dealPic'),
    'petrole3_2': (30, 'dealPic'),
    'petrole3_3': (40, 'dealPic'),
}


@dataclass
class Method:
    # AVM2 method-body header fields between the method index and code length.
    header: tuple[int, ...]
    instructions: list[tuple[str, bytes]]

    def compiled(self, instructions=None):
        code = b''.join(raw for _, raw in (self.instructions if instructions is None else instructions))
        return b''.join(u30(value) for value in (*self.header, len(code))) + code


def u30(value):
    result = bytearray()
    while value >= 0x80:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value)
    return bytes(result)


def export_methods(ffdec, input_file, directory):
    command = ['java', '-Djava.awt.headless=true', '-jar', str(ffdec),
               '-selectclass', 'roles.pets.+,roles.mainrole,fightMain', '-format', 'script:pcodehex',
               '-onerror', 'abort', '-export', 'script', str(directory), str(input_file)]
    subprocess.run(command, check=True)
    scripts = directory / 'scripts'
    methods = {name: parse_methods(scripts / 'roles' / 'pets' / (name + '.pcode'))
               for name in ('petrole', *PET_CLASSES)}
    methods['fightMain'] = parse_methods(scripts / 'fightMain.pcode', only={'bgPicOk', 'creatMainActor'})
    methods['mainrole'] = parse_methods(scripts / 'roles' / 'mainrole.pcode', only={'changState'})
    return methods


def read_raw_methods(ffdec, input_file, keys):
    reader = Path(__file__).with_name('ReadMethodBodies.java')
    selectors = [class_name + ':' + method for class_name, method in keys]
    output = subprocess.check_output(['java', '-Djava.awt.headless=true', '-cp', str(ffdec),
                                      str(reader), str(input_file), *selectors], text=True)
    methods = {}
    for line in output.splitlines():
        selector, index, code = line.split('\t')
        methods[tuple(selector.split(':'))] = (int(index), bytes.fromhex(code))
    if methods.keys() != keys:
        raise ValueError('JPEXS method reader did not return the complete patch target set')
    return methods


def preserve_raw_instructions(method, raw_code):
    offset = 0
    exact = []
    for name, disassembled in method.instructions:
        original = raw_code[offset:offset + len(disassembled)]
        if original[:1] != disassembled[:1]:
            raise ValueError('AVM2 disassembly does not match original instruction layout')
        exact.append((name, original))
        offset += len(disassembled)
    if offset != len(raw_code):
        raise ValueError('AVM2 disassembly and original code lengths differ')
    method.instructions = exact


def parse_methods(path, only=None):
    text = path.read_text(encoding='utf-8')
    declarations = list(re.finditer(r'^\s*(?:\w+ )*function (\w+)\(', text, re.MULTILINE))
    methods = {}
    for i, declaration in enumerate(declarations):
        end = declarations[i + 1].start() if i + 1 < len(declarations) else len(text)
        source = text[declaration.end():end]
        name = declaration[1]
        if only is not None and name not in only:
            continue
        header = re.search(r'\bmaxstack (\d+)\s+localcount (\d+)\s+initscopedepth (\d+)\s+maxscopedepth (\d+)', source)
        code = re.search(r'^\s*code\s*\n(.*?)^\s*end ; code', source, re.MULTILINE | re.DOTALL)
        if name in methods or not header or not code:
            raise ValueError(f'Unexpected FFDec method export: {path.name}:{name}')
        instructions = []
        raw = b''
        for line in code[1].splitlines():
            line = line.strip()
            if re.fullmatch(r'; (?:[0-9a-f]{2} ?)+', line):
                if raw:
                    raise ValueError(f'Unpaired AVM2 bytes: {path.name}:{name}')
                raw = bytes.fromhex(line[2:])
            elif raw and line and not re.fullmatch(r'ofs[0-9a-f]+:', line):
                instructions.append((line, raw))
                raw = b''
        if raw or not instructions:
            raise ValueError(f'Incomplete FFDec method export: {path.name}:{name}')
        methods[name] = Method(tuple(map(int, header.groups())), instructions)
    return methods


def unique_index(indices, context):
    matches = list(indices)
    if len(matches) != 1:
        raise ValueError(f'{context}: expected one instruction match, found {len(matches)}')
    return matches[0]


def patch_energy_check(instructions, cost):
    names = [name for name, _ in instructions]
    marker = ['getlex QName(PackageNamespace(""),"thisCurMp")', f'pushbyte {cost}', 'greaterequals']
    index = unique_index((i for i in range(len(names)) if names[i:i + 3] == marker), 'attack2 MP gate')
    size = sum(len(raw) for _, raw in instructions[index:index + 3])
    # Keep code offsets and the original one-value stack result used by the conditional branch.
    return instructions[:index] + [('pushtrue', b'\x26')] + [('nop', b'\x02')] * (size - 1) + instructions[index + 3:]


def patch_energy_debit(instructions, cost):
    names = [name for name, _ in instructions]
    marker = ['pushstring "mp"', 'callpropvoid QName(PackageNamespace(""),"changState"), 2']
    # One form has an opaque, always-true branch between its constant and the MP string.
    index = unique_index((i for i, name in enumerate(names) if name == f'pushbyte -{cost}'
                          and any(names[j:j + 2] == marker for j in range(i + 1, i + 5))), 'skill MP debit')
    return instructions[:index] + [('pushbyte 0', b'\x24\x00')] + instructions[index + 1:]


def patch_pet_preload(instructions):
    names = [name for name, _ in instructions]
    game_actor_date = 'getproperty QName(PackageNamespace(""),"gameActorDate")'
    role2 = 'getproperty Multiname("role2Date",'
    pet = 'getproperty Multiname("rolePet",'
    selected_pet = 'getproperty Multiname("roleCurPet",'
    index = unique_index((i + 5 for i in range(len(names) - 5) if names[i] == game_actor_date
                          and names[i + 1].startswith(role2) and names[i + 2].startswith(pet)
                          and names[i + 3:i + 5] == ['getlocal0', game_actor_date]
                          and names[i + 5].startswith(selected_pet)), 'player-2 pet selection')
    role2_property = instructions[index - 4]
    branch = unique_index((i + 2 for i in range(index - 10, index - 2)
                           if names[i:i + 2] == ['getproperty QName(PackageNamespace(""),"playerNum")', 'pushbyte 2']
                           and names[i + 2].startswith('ifne ')), 'player-2 mode guard')
    old_branch = instructions[branch][1]
    offset = int.from_bytes(old_branch[1:], 'little', signed=True)
    before_insertion = sum(len(raw) for _, raw in instructions[branch + 1:index])
    if old_branch[:1] != b'\x14' or offset <= before_insertion:
        raise ValueError('Player-2 mode guard no longer skips the pet selection')
    new_branch = b'\x14' + (offset + len(role2_property[1])).to_bytes(3, 'little', signed=True)
    return (instructions[:branch] + [(names[branch], new_branch)]
            + instructions[branch + 1:index] + [role2_property] + instructions[index:])


def build_changes(methods):
    role_creation = methods['fightMain']['creatMainActor'].instructions
    _, mage_reference = reference(role_creation, 'findpropstrict QName(PackageNamespace("roles"),"mainrole2")')
    changes = {
        ('petrole', 'changState'): patch_resources(methods['petrole']['changState'].instructions),
        ('mainrole', 'changState'): patch_resources(methods['mainrole']['changState'].instructions, mage_reference[1:]),
        ('fightMain', 'bgPicOk'): patch_pet_preload(methods['fightMain']['bgPicOk'].instructions),
    }
    for name, (cost, debit_method) in PET_CLASSES.items():
        changes[name, 'attack2'] = patch_energy_check(methods[name]['attack2'].instructions, cost)
        debit = changes.get((name, debit_method), methods[name][debit_method].instructions)
        changes[name, debit_method] = patch_energy_debit(debit, cost)
    return changes


def read_swf(path):
    encoded = path.read_bytes()
    if encoded[:3] not in (b'CWS', b'FWS'):
        raise ValueError(f'Unsupported SWF signature: {path}')
    body = zlib.decompress(encoded[8:]) if encoded[:3] == b'CWS' else encoded[8:]
    if len(body) + 8 != struct.unpack_from('<I', encoded, 4)[0]:
        raise ValueError(f'Unexpected SWF length: {path}')
    cursor = (5 + 4 * (body[0] >> 3) + 7) // 8 + 4  # RECT, frame rate and frame count
    header = body[:cursor]
    tags = []
    while cursor < len(body):
        start = cursor
        tag_code, size = divmod(struct.unpack_from('<H', body, cursor)[0], 64)
        cursor += 2
        if size == 63:
            size = struct.unpack_from('<I', body, cursor)[0]
            cursor += 4
        tags.append((tag_code, body[start:cursor], body[cursor:cursor + size]))
        cursor += size
    if cursor != len(body) or not tags or tags[-1][0] != 0:
        raise ValueError(f'Invalid SWF tag stream: {path}')
    return encoded[3], header, tags


def replace_in_abc(abc, methods, changes, raw_methods):
    edits = []
    for (class_name, name), new_instructions in changes.items():
        method = methods[class_name][name]
        method_index, _ = raw_methods[class_name, name]
        index_prefix = u30(method_index)
        original = index_prefix + method.compiled()
        index = abc.find(original)
        if index < 0 or abc.find(original, index + 1) >= 0:
            raise ValueError(f'{class_name}.{name}: expected one matching compiled AVM2 body')
        end = index + len(original)
        if abc[end] != 0:  # Exception offsets would need to be relocated when adding instructions.
            raise ValueError(f'{class_name}.{name}: unexpected AVM2 exception handlers')
        edits.append((index, end, index_prefix + method.compiled(new_instructions)))
    offset = 0
    pieces = []
    for index, end, replacement in sorted(edits):
        if index < offset:
            raise ValueError('Overlapping pet method edits')
        pieces.extend((abc[offset:index], replacement))
        offset = end
    return b''.join([*pieces, abc[offset:]])


def patch(input_file, output, ffdec, temp):
    version, header, tags = read_swf(input_file)
    index = unique_index((i for i, (tag, _, _) in enumerate(tags) if tag == 82), 'DoABC SWF tag')
    methods = export_methods(ffdec, input_file, temp / 'before')
    targets = {('petrole', 'changState'), ('mainrole', 'changState'), ('fightMain', 'bgPicOk')}
    for name, (_, debit_method) in PET_CLASSES.items():
        targets.update(((name, 'attack2'), (name, debit_method)))
    raw_methods = read_raw_methods(ffdec, input_file, targets)
    for (class_name, name), (_, code) in raw_methods.items():
        preserve_raw_instructions(methods[class_name][name], code)
    changes = build_changes(methods)
    abc = replace_in_abc(tags[index][2], methods, changes, raw_methods)
    tags[index] = (82, struct.pack('<HI', 82 * 64 + 63, len(abc)), abc)
    body = header + b''.join(tag_header + data for _, tag_header, data in tags)
    output.write_bytes(b'CWS' + bytes([version]) + struct.pack('<I', len(body) + 8) + zlib.compress(body))

    # Read the actual emitted program with JPEXS. Verify the target bodies and the remaining
    # disassembly in all pet classes.
    verified = export_methods(ffdec, output, temp / 'after')
    for (class_name, name), (index, code) in read_raw_methods(ffdec, output, targets).items():
        if index != raw_methods[class_name, name][0]:
            raise ValueError(f'{class_name}.{name}: AVM2 method index changed')
        preserve_raw_instructions(verified[class_name][name], code)
    for class_name, class_methods in methods.items():
        if class_methods.keys() != verified[class_name].keys():
            raise ValueError(f'{class_name}: method set changed')
        for name, method in class_methods.items():
            expected = method.compiled(changes.get((class_name, name)))
            if verified[class_name][name].compiled() != expected:
                raise ValueError(f'{class_name}.{name}: emitted method does not match the planned bytecode')
    print(f'Verified {len(changes)} changed method bodies across 10 pet classes, mainrole, and fightMain.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffdec', type=Path, required=True, help='Path to ffdec.jar')
    parser.add_argument('--input', type=Path, required=True, help='Original game.swf or chained patch input')
    parser.add_argument('--output', type=Path, required=True, help='Separate patched SWF output')
    args = parser.parse_args()
    input_file = args.input.resolve(strict=True)
    ffdec = args.ffdec.resolve(strict=True)
    output = args.output.resolve()
    if input_file == output or (output.exists() and input_file.samefile(output)):
        parser.error('Choose an output distinct from the input SWF')
    output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=output.parent) as directory:
        temp = Path(directory)
        patched = temp / 'game.swf'
        patch(input_file, patched, ffdec, temp)
        patched.replace(output)
    print(output)


if __name__ == '__main__':
    main()
