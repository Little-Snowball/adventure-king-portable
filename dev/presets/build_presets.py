"""Generate the two fully progressed mage profiles for the portable launcher."""

import argparse
import json
from pathlib import Path


HERE = Path(__file__).resolve().parent
BASE_KEYS = [65, 68, 87, 83, 74, 75, 76, 49, 50, 51, 52, 67,
             37, 39, 38, 40, 97, 98, 99, 100, 101, 102, 107, 96, 80]
EQUIPMENT_IDS = tuple(str(family + tier) for family in (500, 600, 700, 800, 900)
                      for tier in range(2, 7))
EQUIPPED_IDS = {'weapon': '506', 'helmet': '706', 'shield': '906', 'dress': '806'}
MAGE_AFFIXES = ['mAtt', 'pDef', 'mDef', 'hp', 'mp']
MATERIAL_IDS = tuple(str(item) for item in range(2001, 2006))
PET_IDS = (10103, 10203, 10303)


def equipment(item_id):
    return [item_id, 5, MAGE_AFFIXES.copy(), 1]


def role(name, sex, active_pet):
    in_bag = [equipment(item) for item in EQUIPMENT_IDS if item not in EQUIPPED_IDS.values()]
    materials = [[item, 0, [], 99] for item in MATERIAL_IDS]
    return {
        'roleName': name,
        'roleSex': sex,
        'roleCareer': '法师',
        'roleImage': 3,
        'roleLevel': 40,
        'roleExp': 0,
        'roleEquip': {slot: equipment(item) for slot, item in EQUIPPED_IDS.items()},
        'roleCurPet': active_pet,
        'rpleMoney': 0,
        'roleBag': in_bag + materials,
        'rolePet': [{'id': pet, 'lev': 30, 'exp': 0, 'pk': str(i)}
                    for i, pet in enumerate(PET_IDS, 1)],
    }


def mode(*roles):
    return {
        **{f'role{i}Date': data for i, data in enumerate(roles, 1)},
        'mapArray': [str(level) for level in range(1, 14)],
        'keyArray': BASE_KEYS.copy(),
        # The scoring code starts an uncleared stage with the sum of the earlier scores
        # and treats zero as uncleared. Each synthetic score adds 100 to that baseline.
        'scoreArray': [100 * (1 << stage) for stage in range(13)],
    }


def presets():
    return {
        'single-mage.json': {'onePlayerDate': mode(role('星铃', '女', 0))},
        'double-mage.json': {'twoPlayerDate': mode(role('墨羽', '男', 1), role('星铃', '女', 2))},
    }


def render(value, indent=0):
    """Keep item and scalar array rows on one line for easier manual inspection."""
    if isinstance(value, dict):
        pairs = [f'{" " * (indent + 2)}{json.dumps(key)}: {render(item, indent + 2)}'
                 for key, item in value.items()]
        return '{\n' + ',\n'.join(pairs) + '\n' + ' ' * indent + '}'
    if isinstance(value, list) and value and isinstance(value[0], (dict, list)):
        rows = [f'{" " * (indent + 2)}{render(item, indent + 2)}' for item in value]
        return '[\n' + ',\n'.join(rows) + '\n' + ' ' * indent + ']'
    return json.dumps(value, ensure_ascii=False)


def u29(value):
    """Write a 29-bit unsigned AMF3 integer with a full eight-bit final byte."""
    if not 0 <= value < 1 << 29:
        raise ValueError(f'AMF3 U29 out of range: {value}')
    if value < 1 << 7:
        return bytes([value])
    if value < 1 << 14:
        return bytes([0x80 | (value >> 7), value & 0x7f])
    if value < 1 << 21:
        return bytes([0x80 | (value >> 14), 0x80 | ((value >> 7) & 0x7f), value & 0x7f])
    return bytes([0x80 | (value >> 22), 0x80 | ((value >> 15) & 0x7f),
                  0x80 | ((value >> 8) & 0x7f), value & 0xff])


def amf_string(value):
    data = value.encode('utf-8')
    return u29((len(data) << 1) | 1) + data


def amf_value(value):
    """Write an inline AMF3 value for the preset's plain objects and dense arrays."""
    if type(value) is int and -(1 << 28) <= value < 1 << 28:
        return b'\x04' + u29(value & 0x1fffffff)
    if isinstance(value, str):
        return b'\x06' + amf_string(value)
    if isinstance(value, list):
        return b'\x09' + u29((len(value) << 1) | 1) + b'\x01' + b''.join(map(amf_value, value))
    if isinstance(value, dict):
        # Inline object, inline dynamic traits, zero sealed members, empty alias.
        # Finish the sequence of key/value pairs with the empty inline string.
        pairs = b''.join(amf_string(key) + amf_value(item) for key, item in value.items())
        return b'\x0a\x0b\x01' + pairs + b'\x01'
    raise TypeError(f'Unsupported AMF3 preset value: {value!r}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=HERE)
    parser.add_argument('--check', action='store_true', help='verify the existing files without writing')
    args = parser.parse_args()
    for filename, data in presets().items():
        files = {
            filename: (render(data) + '\n').encode('utf-8'),
            Path(filename).with_suffix('.amf'): amf_value(data),
        }
        for name, payload in files.items():
            path = args.output / name
            if args.check:
                if not path.exists() or path.read_bytes() != payload:
                    parser.exit(1, f'{path} needs to be regenerated\n')
            else:
                args.output.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
            print(path)


if __name__ == '__main__':
    main()
