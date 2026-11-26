"""Gate the baked-in invincibility patches of game.swf behind a runtime flag.

The pet and mage HP/MP refills are injected bytecode in ``game/game.swf`` and the pet
skill energy gate and debit were neutralised there. This step keeps those injections
for the on state and restores the original instructions for the off state, so the
built game can flip invincibility at runtime.

On state: the host writes the flag, the injected refill block runs and neutralises the
restored energy gate and debit. Off state: the guard skips the refill block, so damage
and energy follow the vanilla instructions.
"""

import argparse
import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
import zlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "dev" / "pets"))

import patch_pets  # noqa: E402  (has a __main__ guard)

FLAG = "akInvincible"
# The injected refill block starts at instruction 2 and ends before the original first
# instruction; both classes share the instruction layout and differ in the mage guard.
BLOCK_INSTRUCTIONS = 20
GUARD_TARGETS = {"mainrole": 52, "petrole": 53}
GUARD_SIZE = 8

MAGE_ENTRY = ["getlocal0", 'istype QName(PackageNamespace("roles"),"mainrole2")', "iffalse"]
HP_ENTRY = ["getlocal2", 'pushstring "hp"', "ifne"]
MP_ENTRY = ["getlocal2", 'pushstring "mp"', "ifne"]
HP_FILL = ['findproperty QName(PackageNamespace(""),"thisCurHp")',
           'getlex QName(PackageNamespace(""),"thisAllHp")',
           'initproperty QName(PackageNamespace(""),"thisCurHp")', "pushbyte 0", "setlocal1"]
MP_FILL = HP_FILL.copy()
MP_FILL[0] = 'findproperty QName(PackageNamespace(""),"thisCurMp")'
MP_FILL[1] = 'getlex QName(PackageNamespace(""),"thisAllMp")'
MP_FILL[2] = 'initproperty QName(PackageNamespace(""),"thisCurMp")'
PET_ZERO_GUARD = ['getlex QName(PackageNamespace(""),"thisCurHp")', "pushbyte 0", "ifle"]
REFILL_LAYOUT = {
    "mainrole": MAGE_ENTRY + HP_ENTRY + HP_FILL + ["jump"] + MP_ENTRY + MP_FILL,
    "petrole": HP_ENTRY + PET_ZERO_GUARD + HP_FILL + ["jump"] + MP_ENTRY + MP_FILL,
}


def u30(value):
    result = bytearray()
    while value >= 0x80:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value)
    return bytes(result)


class Cursor:
    """Read the AVM2 constant pools of a DoABC payload."""

    def __init__(self, data, offset):
        self.data = data
        self.off = offset

    def u8(self):
        value = self.data[self.off]
        self.off += 1
        return value

    def u30(self):
        value = 0
        for i in range(5):
            byte = self.data[self.off]
            self.off += 1
            value |= (byte & 0x7F) << (7 * i)
            if not byte & 0x80:
                return value
        raise ValueError("AVM2 u30 is longer than five bytes")

    def u32(self):
        value = 0
        for i in range(5):
            byte = self.data[self.off]
            self.off += 1
            if i == 4:
                value |= byte << 28
                break
            value |= (byte & 0x7F) << (7 * i)
            if not byte & 0x80:
                break
        return value

    def s32(self):
        value = self.u32()
        return value - (1 << 32) if value & (1 << 31) else value

    def string(self):
        length = self.u30()
        value = self.data[self.off:self.off + length]
        self.off += length
        return value


@dataclass
class Abc:
    """Offsets and entries of the DoABC constant pools this step reads or appends to."""

    string_count_pos: int
    string_count: int
    strings: list
    string_end: int
    namespaces: list
    multiname_count_pos: int
    multiname_count: int
    multinames: list
    multiname_end: int


def parse_abc(payload):
    """Layout the constant pools of a DoABC payload, tag prefix included."""
    cursor = Cursor(payload, 0)
    flags = struct.unpack_from("<I", payload, 0)[0]  # DoABC flags is a fixed UI32.
    cursor.off = 4
    name = cursor.string()
    if flags != 1 or name != b"":
        raise ValueError(f"Unexpected DoABC header flags={flags} name={name!r}")
    if struct.unpack_from("<HH", payload, cursor.off) != (16, 46):
        raise ValueError("Unexpected AVM2 version")
    cursor.off += 4

    count = cursor.u30()
    for _ in range(count - 1):
        cursor.s32()
    count = cursor.u30()
    for _ in range(count - 1):
        cursor.u32()
    count = cursor.u30()
    cursor.off += 8 * (count - 1)

    string_count_pos = cursor.off
    string_count = cursor.u30()
    strings = [cursor.string() for _ in range(string_count - 1)]
    string_end = cursor.off

    count = cursor.u30()
    namespaces = []
    for _ in range(count - 1):
        kind = cursor.u8()
        namespaces.append((kind, cursor.u30()))

    count = cursor.u30()
    for _ in range(count - 1):
        for _ in range(cursor.u30()):
            cursor.u30()

    multiname_count_pos = cursor.off
    multiname_count = cursor.u30()
    multinames = []
    for _ in range(multiname_count - 1):
        kind = cursor.u8()
        if kind in (0x07, 0x0D):
            entry = (kind, cursor.u30(), cursor.u30())
        elif kind in (0x0F, 0x10, 0x11, 0x12):
            entry = (kind, cursor.u30(), None)
        elif kind in (0x09, 0x0E):
            entry = (kind, cursor.u30(), cursor.u30())
        elif kind in (0x1B, 0x1C):
            entry = (kind, None, cursor.u30())
        elif kind == 0x1D:
            qname = cursor.u30()
            entry = (kind, qname, tuple(cursor.u30() for _ in range(cursor.u30())))
        else:
            raise ValueError(f"Unknown multiname kind {kind:#x}")
        multinames.append(entry)
    return Abc(string_count_pos, string_count, strings, string_end, namespaces,
               multiname_count_pos, multiname_count, multinames, cursor.off)


def default_package(abc):
    """Return the PackageNamespace("") index every game property is resolved against."""
    empty = [i + 1 for i, (kind, name) in enumerate(abc.namespaces)
             if kind == 0x16 and name > 0 and abc.strings[name - 1] == b""]
    if not empty:
        raise ValueError('The ABC has no PackageNamespace("") entry')
    return empty[0]


def qname_index(abc, name):
    """Return the single default-package QName index carrying ``name``."""
    package = default_package(abc)
    matches = [i + 1 for i, (kind, ns, entry) in enumerate(abc.multinames)
               if kind == 0x07 and ns == package and entry is not None
               and abc.strings[entry - 1] == name.encode("utf-8")]
    if len(matches) != 1:
        raise ValueError(f"Expected one QName for {name!r}, found {matches}")
    return matches[0]


def splice(payload, edits):
    """Apply non-overlapping edits, keeping insertions at their original offsets."""
    result = bytearray()
    cursor = 0
    for start, end, data in sorted(edits):
        if start < cursor:
            raise ValueError("Overlapping ABC edits")
        result += payload[cursor:start] + data
        cursor = end
    return bytes(result + payload[cursor:])


def target_methods():
    """Return {(class, method): [kinds]} for every body this step rewrites."""
    targets = {("mainrole", "changState"): ["guard"], ("petrole", "changState"): ["guard"]}
    for name, (cost, debit_method) in patch_pets.PET_CLASSES.items():
        targets.setdefault((name, "attack2"), []).append(("gate", cost))
        targets.setdefault((name, debit_method), []).append(("debit", cost))
    return targets


def guard_instructions(multiname_index, block_length):
    return [
        ("getlocal0", b"\xd0"),
        (f'getproperty QName(PackageNamespace(""),"{FLAG}")', b"\x66" + u30(multiname_index)),
        ("iffalse", b"\x12" + block_length.to_bytes(3, "little", signed=True)),
    ]


def add_guard(method, block_length, multiname_index):
    if [name for name, _ in method.instructions[:2]] != ["getlocal0", "pushscope"]:
        raise ValueError("Unexpected changState entry")
    block = method.instructions[2:2 + BLOCK_INSTRUCTIONS]
    # Branch operands carry the decompiler's target offset; compare the opcode only.
    names = [name.split(" ofs")[0] for name, _ in block]
    if names != REFILL_LAYOUT[METHOD_OWNER[0]]:
        raise ValueError(f"The injected refill block does not match the expected layout: {names}")
    measured = sum(len(raw) for _, raw in block)
    if measured != block_length:
        raise ValueError(f"The injected refill block is {measured} bytes, expected {block_length}")
    return (method.instructions[:2] + guard_instructions(multiname_index, block_length)
            + method.instructions[2:])


METHOD_OWNER = [""]


def restore_energy_gate(instructions, cost, cur_mp_index):
    names = [name for name, _ in instructions]
    starts = [i for i in range(len(instructions) - 5)
              if names[i] == "pushtrue" and names[i + 1:i + 6] == ["nop"] * 5]
    if len(starts) != 1:
        raise ValueError(f"Expected one pet energy gate for cost {cost}, found {starts}")
    index = starts[0]
    size = sum(len(raw) for _, raw in instructions[index:index + 6])
    if size != 6:
        raise ValueError(f"The pet energy gate for cost {cost} is not six bytes")
    restored = [
        ('getlex QName(PackageNamespace(""),"thisCurMp")', b"\x60" + u30(cur_mp_index)),
        (f"pushbyte {cost}", b"\x24" + bytes([cost])),
        ("greaterequals", b"\xb0"),  # 0xAF is greaterthan; the game uses 0xB0.
    ]
    return instructions[:index] + restored + instructions[index + 6:]


def restore_energy_debit(instructions, cost):
    names = [name for name, _ in instructions]
    marker = ['pushstring "mp"', 'callpropvoid QName(PackageNamespace(""),"changState"), 2']
    starts = [i for i in range(len(instructions))
              if names[i] == "pushbyte 0"
              and any(names[j:j + 2] == marker for j in range(i + 1, i + 5))]
    if len(starts) != 1:
        raise ValueError(f"Expected one pet energy debit for cost {cost}, found {starts}")
    index = starts[0]
    if instructions[index][1] != b"\x24\x00":
        raise ValueError(f"The pet energy debit for cost {cost} is not a zero pushbyte")
    return (instructions[:index]
            + [(f"pushbyte -{cost}", b"\x24" + bytes([(256 - cost) & 0xFF]))]
            + instructions[index + 1:])


def plan_changes(methods, multiname_index, cur_mp_index):
    """Build the rewritten bodies and prove the length contract of every edit."""
    plan = {}
    for (class_name, method_name), kinds in target_methods().items():
        method = methods[class_name][method_name]
        instructions = method.instructions
        for kind in kinds:
            if kind == "guard":
                METHOD_OWNER[0] = class_name
                instructions = add_guard(method, GUARD_TARGETS[class_name], multiname_index)
            elif kind[0] == "gate":
                instructions = restore_energy_gate(instructions, kind[1], cur_mp_index)
            else:
                instructions = restore_energy_debit(instructions, kind[1])
        original = sum(len(raw) for _, raw in method.instructions)
        expected = original + GUARD_SIZE if kinds == ["guard"] else original
        measured = sum(len(raw) for _, raw in instructions)
        if measured != expected:
            raise ValueError(f"{class_name}.{method_name}: {measured} bytes, expected {expected}")
        plan[class_name, method_name] = patch_pets.Method(method.header, instructions)
    return plan


def export_methods(ffdec, input_file, directory):
    command = ["java", "-Djava.awt.headless=true", "-jar", str(ffdec),
               "-selectclass", "roles.mainrole,roles.pets.+", "-format", "script:pcodehex",
               "-onerror", "abort", "-export", "script", str(directory), str(input_file)]
    subprocess.run(command, check=True)
    scripts = directory / "scripts"
    methods = {"mainrole": patch_pets.parse_methods(scripts / "roles" / "mainrole.pcode"),
               "petrole": patch_pets.parse_methods(scripts / "roles" / "pets" / "petrole.pcode")}
    for name in patch_pets.PET_CLASSES:
        methods[name] = patch_pets.parse_methods(scripts / "roles" / "pets" / (name + ".pcode"))
    return methods


def read_raw_methods(ffdec, input_file):
    reader = ROOT / "dev" / "pets" / "ReadMethodBodies.java"
    selectors = [f"{class_name}:{method_name}" for class_name, method_name in target_methods()]
    output = subprocess.check_output(["java", "-Djava.awt.headless=true", "-cp", str(ffdec),
                                      str(reader), str(input_file), *selectors], text=True)
    methods = {}
    for line in output.splitlines():
        selector, index, code = line.split("\t")
        methods[tuple(selector.split(":"))] = (int(index), bytes.fromhex(code))
    if methods.keys() != set(target_methods()):
        raise ValueError("The method reader did not return the complete target set")
    return methods


def abc_of(path):
    """Return the single DoABC tag index and payload of an SWF."""
    version, header, tags = patch_pets.read_swf(path)
    indexes = [i for i, (tag, _, _) in enumerate(tags) if tag == 82]
    if len(indexes) != 1:
        raise ValueError("Expected exactly one DoABC tag")
    return version, header, tags, indexes[0], tags[indexes[0]][2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffdec", type=Path, required=True, help="Path to ffdec.jar")
    parser.add_argument("--input", type=Path, required=True, help="Patched game.swf")
    parser.add_argument("--output", type=Path, required=True, help="New SWF output")
    parser.add_argument("--inspect", action="store_true", help="Print the ABC pools and stop")
    args = parser.parse_args()
    input_file = args.input.resolve(strict=True)
    ffdec = args.ffdec.resolve(strict=True)
    output = args.output.resolve()
    if input_file == output or (output.exists() and input_file.samefile(output)):
        parser.error("Choose an output distinct from the input SWF")

    version, header, tags, tag_index, payload = abc_of(input_file)
    abc = parse_abc(payload)
    cur_mp_index = qname_index(abc, "thisCurMp")

    if args.inspect:
        print(f"payload {len(payload)}")
        print(f"string count {abc.string_count} at {abc.string_count_pos}, end {abc.string_end}")
        print(f"namespace entries {len(abc.namespaces)}")
        print(f"multiname count {abc.multiname_count} at {abc.multiname_count_pos}, "
              f"end {abc.multiname_end}")
        print(f'PackageNamespace("") index {default_package(abc)}, thisCurMp {cur_mp_index}')
        print("multiname 793:", abc.multinames[791],
              abc.strings[abc.multinames[791][2] - 1].decode())
        print(f"flag string present: {FLAG.encode() in abc.strings}")
        return

    if FLAG.encode() in abc.strings:
        raise SystemExit("game.swf already carries the invincibility flag; refusing to patch twice")

    output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=output.parent) as directory:
        work = Path(directory)
        methods = export_methods(ffdec, input_file, work / "before")
        if any(FLAG in name for class_methods in methods.values()
               for class_method in class_methods.values() for name, _ in class_method.instructions):
            raise SystemExit("game.swf already carries the invincibility guard")
        raw_methods = read_raw_methods(ffdec, input_file)
        for (class_name, method_name), (_, code) in raw_methods.items():
            patch_pets.preserve_raw_instructions(methods[class_name][method_name], code)

        plan = plan_changes(methods, abc.multiname_count, cur_mp_index)
        edits = []
        for (class_name, method_name), method in plan.items():
            method_index, _ = raw_methods[class_name, method_name]
            original = u30(method_index) + methods[class_name][method_name].compiled()
            start = payload.find(original)
            if start < 0 or payload.find(original, start + 1) >= 0:
                raise ValueError(f"{class_name}.{method_name}: expected one compiled body")
            end = start + len(original)
            if payload[end] != 0:  # A zero exception count follows the body.
                raise ValueError(f"{class_name}.{method_name}: unexpected exception handlers")
            edits.append((start, end, u30(method_index) + method.compiled()))

        edits.append((abc.string_count_pos, abc.string_count_pos + len(u30(abc.string_count)),
                      u30(abc.string_count + 1)))
        edits.append((abc.string_end, abc.string_end, u30(len(FLAG)) + FLAG.encode()))
        edits.append((abc.multiname_count_pos,
                      abc.multiname_count_pos + len(u30(abc.multiname_count)),
                      u30(abc.multiname_count + 1)))
        edits.append((abc.multiname_end, abc.multiname_end,
                      b"\x07" + u30(default_package(abc)) + u30(abc.string_count)))
        patched = splice(payload, edits)

        tags[tag_index] = (82, struct.pack("<HI", 82 * 64 + 63, len(patched)), patched)
        body = header + b"".join(tag_header + data for _, tag_header, data in tags)
        output.write_bytes(b"CWS" + bytes([version]) + struct.pack("<I", len(body) + 8)
                           + zlib.compress(body))
        print(f"wrote {output} ({output.stat().st_size} bytes, abc {len(patched)} bytes)")
        verify(ffdec, output, plan, work / "after", abc)


def verify(ffdec, output, plan, directory, before):
    """Re-read the emitted SWF and prove the planned bytecode and pools landed."""
    methods = export_methods(ffdec, output, directory)
    raw_methods = read_raw_methods(ffdec, output)
    for (class_name, method_name), (_, code) in raw_methods.items():
        patch_pets.preserve_raw_instructions(methods[class_name][method_name], code)
    for (class_name, method_name), method in plan.items():
        if methods[class_name][method_name].compiled() != method.compiled():
            raise ValueError(f"{class_name}.{method_name}: emitted body differs from the plan")

    _, _, _, _, payload = abc_of(output)
    after = parse_abc(payload)
    if after.string_count != before.string_count + 1 or after.strings[-1] != FLAG.encode():
        raise ValueError("The flag string was not appended exactly once")
    if after.multiname_count != before.multiname_count + 1:
        raise ValueError("The flag multiname was not appended exactly once")
    kind, ns, name = after.multinames[before.multiname_count - 1]
    if kind != 0x07 or ns != default_package(after) or name != before.string_count:
        raise ValueError("The flag multiname is not a default-package QName of the new string")
    if after.multinames[791] != before.multinames[791]:
        raise ValueError("Multiname 793 drifted")
    if qname_index(after, "changState") != qname_index(before, "changState"):
        raise ValueError("An existing multiname index drifted")

    for class_name, block_length in GUARD_TARGETS.items():
        guard = methods[class_name]["changState"].instructions[2:5]
        names = [name.split(" ofs")[0] for name, _ in guard]
        if names != ["getlocal0", f'getproperty QName(PackageNamespace(""),"{FLAG}")', "iffalse"]:
            raise ValueError(f"{class_name}.changState: the guard is not in place: {names}")
        if int.from_bytes(guard[2][1][1:], "little", signed=True) != block_length:
            raise ValueError(f"{class_name}.changState: the guard does not skip the refill block")
    cur_mp = qname_index(before, "thisCurMp")
    for class_name, (cost, debit_method) in patch_pets.PET_CLASSES.items():
        attack = methods[class_name]["attack2"].instructions
        names = [name for name, _ in attack]
        neutralised = [i for i in range(len(names) - 5)
                       if names[i] == "pushtrue" and names[i + 1:i + 6] == ["nop"] * 5]
        if neutralised:
            raise ValueError(f"{class_name}.attack2: the energy gate is still neutralised")
        raws = [raw for _, raw in attack]
        gate = [b"\x60" + u30(cur_mp), b"\x24" + bytes([cost]), b"\xb0"]
        found = [i for i in range(len(raws) - 2) if raws[i:i + 3] == gate]
        if len(found) != 1:
            raise ValueError(f"{class_name}.attack2: the energy gate was not restored")
        # Prove the semantics with the decompiler's own names, not only with our bytes.
        if names[found[0]:found[0] + 3] != ['getlex QName(PackageNamespace(""),"thisCurMp")',
                                            f"pushbyte {cost}", "greaterequals"]:
            raise ValueError(f"{class_name}.attack2: the restored gate is not a MP comparison")
        debit = [raw for name, raw in methods[class_name][debit_method].instructions
                 if name == f"pushbyte -{cost}"]
        if debit != [b"\x24" + bytes([(256 - cost) & 0xFF])]:
            raise ValueError(f"{class_name}.{debit_method}: the energy debit was not restored")
    print(f"verified {len(plan)} bodies, guard offsets {GUARD_TARGETS}, pool counts +1/+1")


if __name__ == "__main__":
    main()
