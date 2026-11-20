"""Assemble the AVM2 HP/MP update prologue for pets and mage actors."""


def branch_over(op, opcode, instructions):
    length = sum(len(raw) for _, raw in instructions)
    return op, bytes([opcode]) + length.to_bytes(3, 'little', signed=True)


def reference(instructions, name):
    matches = {raw for op, raw in instructions if op == name}
    if len(matches) != 1:
        raise ValueError(f'Expected one AVM2 reference encoding for {name}')
    return name, matches.pop()


def fill_stat(instructions, stat):
    current = f'QName(PackageNamespace(""),"thisCur{stat}")'
    maximum = f'QName(PackageNamespace(""),"thisAll{stat}")'
    return [reference(instructions, f'findproperty {current}'),
            reference(instructions, f'getlex {maximum}'),
            reference(instructions, f'initproperty {current}'),
            ('pushbyte 0', b'\x24\x00'), ('setlocal1', b'\xd5')]


def patch_resources(instructions, mage_type=None):
    if [name for name, _ in instructions[:2]] != ['getlocal0', 'pushscope']:
        raise ValueError('Unexpected changState method entry')
    mp_fill = fill_stat(instructions, 'Mp')
    mp_block = [('getlocal2', b'\xd2'), reference(instructions, 'pushstring "mp"'),
                branch_over('ifne', 0x14, mp_fill), *mp_fill]
    hp_fill = fill_stat(instructions, 'Hp') + [branch_over('jump', 0x10, mp_block)]
    if mage_type is None:
        # The master's cleanup directly sets pet HP to 0. Leave that sentinel intact.
        zero_guard = [reference(instructions, 'getlex QName(PackageNamespace(""),"thisCurHp")'),
                      ('pushbyte 0', b'\x24\x00'), branch_over('ifle', 0x16, hp_fill)]
        hp_fill = zero_guard + hp_fill
    hp_block = [('getlocal2', b'\xd2'), reference(instructions, 'pushstring "hp"'),
                branch_over('ifne', 0x14, hp_fill), *hp_fill]
    refill = hp_block + mp_block
    if mage_type is not None:
        mage_guard = [('getlocal0', b'\xd0'), ('istype roles.mainrole2', b'\xb2' + mage_type),
                      branch_over('iffalse', 0x12, refill)]
        refill = mage_guard + refill
    # Assign the live maximum and zero the delta before the normal HUD update. All old
    # instructions move together, preserving relative branches within the original code.
    return instructions[:2] + refill + instructions[2:]
