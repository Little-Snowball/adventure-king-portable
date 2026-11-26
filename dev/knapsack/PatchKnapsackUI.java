import com.jpexs.decompiler.flash.SWF;
import com.jpexs.decompiler.flash.abc.ABC;
import com.jpexs.decompiler.flash.abc.avm2.AVM2Code;
import com.jpexs.decompiler.flash.abc.avm2.instructions.AVM2Instruction;
import com.jpexs.decompiler.flash.abc.types.InstanceInfo;
import com.jpexs.decompiler.flash.abc.types.MethodBody;
import com.jpexs.decompiler.flash.abc.types.Multiname;
import com.jpexs.decompiler.flash.abc.types.Namespace;
import com.jpexs.decompiler.flash.abc.types.traits.Trait;
import com.jpexs.decompiler.flash.abc.types.traits.TraitMethodGetterSetter;
import com.jpexs.decompiler.flash.tags.ABCContainerTag;
import com.jpexs.decompiler.flash.tags.DefineShape3Tag;
import com.jpexs.decompiler.flash.tags.DefineSpriteTag;
import com.jpexs.decompiler.flash.tags.PlaceObject2Tag;
import com.jpexs.decompiler.flash.tags.PlaceObject3Tag;
import com.jpexs.decompiler.flash.tags.Tag;
import com.jpexs.decompiler.flash.types.shaperecords.SHAPERECORD;
import com.jpexs.decompiler.flash.types.shaperecords.StyleChangeRecord;

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static com.jpexs.decompiler.flash.abc.avm2.instructions.AVM2Instructions.*;

/**
 * Clean up Knapsack UI in game.swf:
 * 1. Remove all prohibition icons (bag grid unuse, 8 unused equip slots, left-hand 2H overlay).
 * 2. Remove sort ("整理"), expand ("扩容"), and currency ("钝币", "哈斯币") UI & code.
 * 3. Fix initial and open-time capacity text so the equipment tab displays count/60.
 */
public final class PatchKnapsackUI {
    private final SWF swf;
    private final ABC abc;
    private final InstanceInfo knapsackInfo;
    private final int equipCapQName;
    private final int itemCapQName;
    private final int elseCapQName;
    private final int paneStateQName;
    private final int goodsCountQName;
    private final int setGoodsSpaceQName;
    private final int multinameL;

    private PatchKnapsackUI(SWF swf, ABC abc) {
        this.swf = swf;
        this.abc = abc;
        this.knapsackInfo = findInstance("Knapsack");
        this.equipCapQName = findTraitQName(knapsackInfo, "mCrtEquipCapacity");
        this.itemCapQName = findTraitQName(knapsackInfo, "mCrtItemCapacity");
        this.elseCapQName = findTraitQName(knapsackInfo, "mCrtElseCapacity");
        this.paneStateQName = findTraitQName(knapsackInfo, "mPaneState");
        this.goodsCountQName = findTraitQName(knapsackInfo, "m_aGoodsCount");
        this.setGoodsSpaceQName = findTraitQName(knapsackInfo, "setGoodsSpace");
        this.multinameL = findInstructionOperand("Knapsack", "openKnapsack", GetProperty, null, true);
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new IllegalStateException(message);
    }

    private String mnName(int multiname) {
        if (multiname <= 0) return "";
        int ni = abc.constants.getMultiname(multiname).name_index;
        return ni > 0 ? abc.constants.getString(ni) : "";
    }

    private InstanceInfo findInstance(String simpleName) {
        for (InstanceInfo info : abc.instance_info) {
            if (mnName(info.name_index).equals(simpleName)) return info;
        }
        throw new IllegalStateException("Missing ABC class: " + simpleName);
    }

    private int findTraitQName(InstanceInfo info, String name) {
        for (Trait tr : info.instance_traits.traits) {
            if (mnName(tr.name_index).equals(name)) return tr.name_index;
        }
        throw new IllegalStateException("Missing trait " + name);
    }

    private MethodBody methodBody(String name) {
        for (Trait tr : knapsackInfo.instance_traits.traits) {
            if (tr instanceof TraitMethodGetterSetter && mnName(tr.name_index).equals(name)) {
                return abc.findBody(((TraitMethodGetterSetter) tr).method_info);
            }
        }
        throw new IllegalStateException("Missing Knapsack method: " + name);
    }

    private int findInstructionOperand(String className, String methodName, int opcode, String nameFilter, boolean wantMultinameL) {
        MethodBody body = methodBody(methodName);
        for (AVM2Instruction ins : body.getCode().code) {
            if (is(ins, opcode)) {
                Multiname mn = abc.constants.getMultiname(ins.operands[0]);
                if (wantMultinameL && mn.kind == Multiname.MULTINAMEL) return ins.operands[0];
                if (nameFilter != null && mnName(ins.operands[0]).equals(nameFilter)) return ins.operands[0];
            }
        }
        throw new IllegalStateException("Operand not found in " + className + "." + methodName);
    }

    private static boolean is(AVM2Instruction ins, int opcode) {
        return ins.definition == AVM2Code.instructionSet[opcode];
    }

    private static AVM2Instruction instruction(int opcode, int... operands) {
        return new AVM2Instruction(0, opcode, operands);
    }

    private static int branchTarget(AVM2Instruction ins, int operand) {
        int origin = Math.toIntExact(ins.getAddress());
        if (!is(ins, LookupSwitch)) origin += ins.getBytesLength();
        return origin + ins.operands[operand];
    }

    private static boolean isBranch(AVM2Instruction ins) {
        int c = ins.definition.instructionCode;
        return is(ins, LookupSwitch) || (c >= IfNLt && c <= IfStrictNe);
    }

    private static Map<AVM2Instruction, List<AVM2Instruction>> captureBranches(MethodBody body) {
        var result = new IdentityHashMap<AVM2Instruction, List<AVM2Instruction>>();
        var addresses = new HashMap<Integer, AVM2Instruction>();
        for (var ins : body.getCode().code) {
            addresses.put(Math.toIntExact(ins.getAddress()), ins);
        }
        for (var ins : body.getCode().code) {
            if (is(ins, LookupSwitch)) {
                var targets = new ArrayList<AVM2Instruction>();
                targets.add(addresses.get(branchTarget(ins, 0)));
                for (int i = 2; i < ins.operands.length; i++) {
                    targets.add(addresses.get(branchTarget(ins, i)));
                }
                for (var t : targets) require(t != null, "Invalid LookupSwitch target");
                result.put(ins, targets);
            } else if (isBranch(ins)) {
                var t = addresses.get(branchTarget(ins, 0));
                require(t != null, "Invalid branch target");
                result.put(ins, List.of(t));
            }
        }
        return result;
    }

    /** Delete [start..end] inclusive, redirecting any branch targeting start to end + 1. */
    private static void deleteRange(MethodBody body, int start, int end) {
        List<AVM2Instruction> code = body.getCode().code;
        require(start >= 0 && end >= start && end + 1 < code.size(), "Invalid deleteRange");
        AVM2Instruction first = code.get(start);
        AVM2Instruction after = code.get(end + 1);
        Set<AVM2Instruction> interior = CollectionsUtil.identitySet(code.subList(start + 1, end + 1));

        var branches = captureBranches(body);
        var updated = new IdentityHashMap<AVM2Instruction, List<AVM2Instruction>>();
        for (var entry : branches.entrySet()) {
            AVM2Instruction br = entry.getKey();
            if (br == first || interior.contains(br)) continue;
            List<AVM2Instruction> newTargets = new ArrayList<>();
            for (AVM2Instruction tgt : entry.getValue()) {
                require(!interior.contains(tgt), "Branch jumps into middle of deleted range");
                newTargets.add(tgt == first ? after : tgt);
            }
            updated.put(br, newTargets);
        }

        for (int i = end; i >= start; i--) {
            code.remove(i);
        }
        fixBranchOffsets(body, updated);
    }

    /** Replace [start..end] inclusive with replacement instructions, redirecting branches targeting start. */
    private static void replaceRange(MethodBody body, int start, int end, List<AVM2Instruction> replacement) {
        List<AVM2Instruction> code = body.getCode().code;
        require(start >= 0 && end >= start && !replacement.isEmpty(), "Invalid replaceRange");
        AVM2Instruction first = code.get(start);
        AVM2Instruction newFirst = replacement.get(0);
        Set<AVM2Instruction> interior = CollectionsUtil.identitySet(code.subList(start + 1, end + 1));

        var branches = captureBranches(body);
        var updated = new IdentityHashMap<AVM2Instruction, List<AVM2Instruction>>();
        for (var entry : branches.entrySet()) {
            AVM2Instruction br = entry.getKey();
            if (br == first || interior.contains(br)) continue;
            List<AVM2Instruction> newTargets = new ArrayList<>();
            for (AVM2Instruction tgt : entry.getValue()) {
                require(!interior.contains(tgt), "Branch jumps into middle of replaced range");
                newTargets.add(tgt == first ? newFirst : tgt);
            }
            updated.put(br, newTargets);
        }

        for (int i = end; i >= start; i--) {
            code.remove(i);
        }
        code.addAll(start, replacement);
        fixBranchOffsets(body, updated);
    }

    private static void fixBranchOffsets(MethodBody body, Map<AVM2Instruction, List<AVM2Instruction>> branches) {
        body.markOffsets();
        for (var entry : branches.entrySet()) {
            AVM2Instruction br = entry.getKey();
            List<AVM2Instruction> targets = entry.getValue();
            if (is(br, LookupSwitch)) {
                int[] ops = br.operands.clone();
                ops[0] = Math.toIntExact(targets.get(0).getAddress() - br.getAddress());
                for (int j = 1; j < targets.size(); j++) {
                    ops[j + 1] = Math.toIntExact(targets.get(j).getAddress() - br.getAddress());
                }
                br.setOperands(ops, body.getCode(), body);
            } else {
                int offset = Math.toIntExact(targets.get(0).getAddress() - br.getAddress() - br.getBytesLength());
                br.setOperands(new int[] { offset }, body.getCode(), body);
            }
        }
        body.markOffsets();
        body.setCode(body.getCode());
    }

    private static final class CollectionsUtil {
        static Set<AVM2Instruction> identitySet(List<AVM2Instruction> list) {
            Set<AVM2Instruction> set = java.util.Collections.newSetFromMap(new IdentityHashMap<>());
            set.addAll(list);
            return set;
        }
    }

    private static final class Block {
        final List<AVM2Instruction> code = new ArrayList<>();
        final Map<String, List<AVM2Instruction>> fixups = new HashMap<>();
        final Map<String, Integer> labels = new HashMap<>();

        void emit(int opcode, int... operands) {
            code.add(instruction(opcode, operands));
        }

        void branch(int opcode, String label) {
            AVM2Instruction br = instruction(opcode, 0);
            code.add(br);
            fixups.computeIfAbsent(label, ignored -> new ArrayList<>()).add(br);
        }

        void mark(String label) {
            require(labels.put(label, code.size()) == null, "Duplicate label " + label);
        }

        void resolveInternal(MethodBody body, int baseIndex) {
            body.markOffsets();
            for (var entry : fixups.entrySet()) {
                AVM2Instruction target = body.getCode().code.get(baseIndex + labels.get(entry.getKey()));
                for (AVM2Instruction br : entry.getValue()) {
                    int offset = Math.toIntExact(target.getAddress() - br.getAddress() - br.getBytesLength());
                    br.setOperands(new int[] { offset }, body.getCode(), body);
                }
            }
            body.markOffsets();
            body.setCode(body.getCode());
        }
    }

    // ---- SWF Sprite & Shape cleanup ----

    private void patchSpritesAndShapes() {
        // 1. mcGoodsPane (Sprite 236): remove depth=2 wk_mcGoodsPane_unuse (chId=235)
        DefineSpriteTag goodsPane = (DefineSpriteTag) swf.getCharacter(236);
        int removedUnuse = removePlacements(goodsPane, Set.of(2), Set.of(235));
        require(removedUnuse == 1, "Expected 1 wk_mcGoodsPane_unuse placement in mcGoodsPane, removed " + removedUnuse);

        // 2. mcKnapsack (Sprite 640):
        //    - depths 51..58, 60: dun & hasi icons/labels
        //    - depth 91 (wk_mcKnapsack_txtDun), depth 92 (wk_mcKnapsack_txtHasi)
        //    - depth 144 (wk_mcKnapsack_btnSort), depth 148 (expand button chId=617)
        //    - depths 160..167 (8 red prohibition icons), depth 168 (wk_mcKnapsack_mcLefeHand)
        DefineSpriteTag knapsackSpr = (DefineSpriteTag) swf.getCharacter(640);
        Set<Integer> removeDepths = Set.of(
            51, 52, 53, 54, 55, 56, 57, 58, 60,
            91, 92,
            144, 148,
            160, 161, 162, 163, 164, 165, 166, 167, 168
        );
        Set<Integer> expectedChIds = Set.of(
            276, 277, 278, 279, 280, 271, 272, 282, 274,
            547, 548,
            605, 617,
            630, 631, 632, 633, 634, 635, 636, 637, 639
        );
        int removedKnapsack = removePlacements(knapsackSpr, removeDepths, expectedChIds);
        require(removedKnapsack == removeDepths.size(),
            "Expected " + removeDepths.size() + " placements removed from mcKnapsack, got " + removedKnapsack);

        // 3. Shape 477: remove the two bottom-right input box sub-paths for 钝币 & 哈斯币 (records 339..375)
        DefineShape3Tag bgBoxes = (DefineShape3Tag) swf.getCharacter(477);
        List<SHAPERECORD> recs = bgBoxes.shapes.shapeRecords;
        require(recs.size() == 468, "Unexpected Shape 477 record count: " + recs.size());
        StyleChangeRecord startDun = (StyleChangeRecord) recs.get(339);
        StyleChangeRecord nextBox = (StyleChangeRecord) recs.get(376);
        require(startDun.stateMoveTo && startDun.moveDeltaX == 8362 && startDun.moveDeltaY == 6680,
            "Shape 477 dun box start mismatch");
        require(nextBox.stateMoveTo && nextBox.moveDeltaX == 3314 && nextBox.moveDeltaY == 830,
            "Shape 477 next box start mismatch");
        for (int i = 375; i >= 339; i--) {
            recs.remove(i);
        }
        bgBoxes.setModified(true);
    }

    private int removePlacements(DefineSpriteTag sprite, Set<Integer> depths, Set<Integer> allowedChIds) {
        int count = 0;
        for (Iterator<Tag> it = sprite.getTags().iterator(); it.hasNext(); ) {
            Tag tag = it.next();
            if (tag instanceof PlaceObject2Tag) {
                PlaceObject2Tag p = (PlaceObject2Tag) tag;
                if (depths.contains(p.depth)) {
                    require(allowedChIds.contains(p.characterId),
                        "Unexpected chId " + p.characterId + " at depth " + p.depth);
                    it.remove();
                    count++;
                }
            } else if (tag instanceof PlaceObject3Tag) {
                PlaceObject3Tag p = (PlaceObject3Tag) tag;
                if (depths.contains(p.depth)) {
                    require(allowedChIds.contains(p.characterId),
                        "Unexpected chId " + p.characterId + " at depth " + p.depth);
                    it.remove();
                    count++;
                }
            }
        }
        if (count > 0) sprite.setModified(true);
        return count;
    }

    // ---- ABC Bytecode cleanup & fixes ----

    private void patchKnapsackCode() {
        patchConstructor();
        patchOpenKnapsack();
        patchUpdate();
        patchLoadGoodsPane();
        removeSetCapacityCalls();
        removeLefeHandWrites();
        removeSortListeners();
        removeSortFlags();
        removeDeadPushGoodsSpace();
        removeTraits();
    }

    private void patchConstructor() {
        MethodBody ctor = abc.findBody(knapsackInfo.iinit_index);
        List<AVM2Instruction> code = ctor.getCode().code;

        // Ensure mCrtEquipCapacity = 60
        boolean capUpdated = false;
        for (int i = 1; i < code.size(); i++) {
            if (is(code.get(i), InitProperty) && code.get(i).operands[0] == equipCapQName) {
                require(is(code.get(i - 1), PushByte), "Expected PushByte for mCrtEquipCapacity");
                if (code.get(i - 1).operands[0] != 60) {
                    code.get(i - 1).setOperands(new int[] { 60 }, ctor.getCode(), ctor);
                }
                capUpdated = true;
                break;
            }
        }
        require(capUpdated, "Did not find mCrtEquipCapacity init in Knapsack.<init>");

        // Change final setGoodsSpace(m_aGoodsCount[1], mCrtItemCapacity) -> (m_aGoodsCount[0], mCrtEquipCapacity)
        int matches = 0;
        for (int i = 0; i <= code.size() - 8; i++) {
            if (is(code.get(i), GetLocal0)
                    && is(code.get(i + 1), GetLocal0)
                    && is(code.get(i + 2), GetProperty) && code.get(i + 2).operands[0] == goodsCountQName
                    && is(code.get(i + 3), PushByte) && code.get(i + 3).operands[0] == 1
                    && is(code.get(i + 4), GetProperty) && code.get(i + 4).operands[0] == multinameL
                    && is(code.get(i + 5), GetLocal0)
                    && is(code.get(i + 6), GetProperty) && code.get(i + 6).operands[0] == itemCapQName
                    && is(code.get(i + 7), CallPropVoid) && code.get(i + 7).operands[0] == setGoodsSpaceQName) {
                code.get(i + 3).setOperands(new int[] { 0 }, ctor.getCode(), ctor);
                code.get(i + 6).setOperands(new int[] { equipCapQName }, ctor.getCode(), ctor);
                matches++;
            }
        }
        require(matches == 1, "Expected 1 setGoodsSpace in Knapsack.<init>, found " + matches);
        ctor.markOffsets();
        ctor.setCode(ctor.getCode());
    }

    private void patchOpenKnapsack() {
        MethodBody body = methodBody("openKnapsack");
        List<AVM2Instruction> code = body.getCode().code;
        int start = -1, end = -1;
        for (int i = 0; i <= code.size() - 9; i++) {
            if (is(code.get(i), GetLocal0)
                    && is(code.get(i + 1), GetLocal0)
                    && is(code.get(i + 2), GetProperty) && code.get(i + 2).operands[0] == goodsCountQName
                    && is(code.get(i + 3), PushByte) && code.get(i + 3).operands[0] == 1
                    && is(code.get(i + 4), GetProperty) && code.get(i + 4).operands[0] == multinameL
                    && is(code.get(i + 5), GetLocal0)
                    && is(code.get(i + 6), GetProperty) && code.get(i + 6).operands[0] == itemCapQName) {
                // Skip optional dead branch: pushfalse, iffalse, returnvoid
                int callIdx = i + 7;
                if (is(code.get(callIdx), PushFalse) && is(code.get(callIdx + 1), IfFalse) && is(code.get(callIdx + 2), ReturnVoid)) {
                    callIdx += 3;
                }
                if (is(code.get(callIdx), CallPropVoid) && code.get(callIdx).operands[0] == setGoodsSpaceQName) {
                    start = i;
                    end = callIdx;
                    break;
                }
            }
        }
        require(start >= 0, "Could not locate setGoodsSpace in openKnapsack");

        int strItem = abc.constants.getStringId("道具", true);
        int strElse = abc.constants.getStringId("特殊", true);

        Block blk = new Block();
        // if (this.mPaneState == "道具") setGoodsSpace(m_aGoodsCount[1], mCrtItemCapacity);
        blk.emit(GetLocal0);
        blk.emit(GetProperty, paneStateQName);
        blk.emit(PushString, strItem);
        blk.branch(IfNe, "checkElse");
        emitSetSpace(blk, 1, itemCapQName);
        blk.branch(Jump, "done");

        // else if (this.mPaneState == "特殊") setGoodsSpace(m_aGoodsCount[2], mCrtElseCapacity);
        blk.mark("checkElse");
        blk.emit(GetLocal0);
        blk.emit(GetProperty, paneStateQName);
        blk.emit(PushString, strElse);
        blk.branch(IfNe, "equip");
        emitSetSpace(blk, 2, elseCapQName);
        blk.branch(Jump, "done");

        // else setGoodsSpace(m_aGoodsCount[0], mCrtEquipCapacity);
        blk.mark("equip");
        emitSetSpace(blk, 0, equipCapQName);
        blk.mark("done");
        blk.emit(Nop);

        replaceRange(body, start, end, blk.code);
        blk.resolveInternal(body, start);
    }

    private void emitSetSpace(Block blk, int countIndex, int capQName) {
        blk.emit(GetLocal0);
        blk.emit(GetLocal0);
        blk.emit(GetProperty, goodsCountQName);
        blk.emit(PushByte, countIndex);
        blk.emit(GetProperty, multinameL);
        blk.emit(GetLocal0);
        blk.emit(GetProperty, capQName);
        blk.emit(CallPropVoid, setGoodsSpaceQName, 2);
    }

    private void patchUpdate() {
        MethodBody body = methodBody("update");
        List<AVM2Instruction> code = body.getCode().code;
        int retIdx = code.size() - 1;
        require(is(code.get(retIdx), ReturnVoid), "Expected ReturnVoid at end of update()");
        int strEquip = abc.constants.getStringId("装备", true);

        Block blk = new Block();
        blk.emit(GetLocal0);
        blk.emit(PushString, strEquip);
        blk.emit(InitProperty, paneStateQName);
        emitSetSpace(blk, 0, equipCapQName);
        body.insertAll(retIdx, blk.code);
        body.markOffsets();
        body.setCode(body.getCode());
    }

    private void patchLoadGoodsPane() {
        MethodBody body = methodBody("loadGoodsPane");
        List<AVM2Instruction> code = body.getCode().code;

        int hits = 0;
        for (int i = 0; i <= code.size() - 7; i++) {
            if (is(code.get(i), GetLocal3)
                    && is(code.get(i + 1), GetLocal2)
                    && is(code.get(i + 2), IfNLt)
                    && is(code.get(i + 3), GetLocal) && code.get(i + 3).operands[0] == 4
                    && is(code.get(i + 4), GetProperty) && mnName(code.get(i + 4).operands[0]).equals("wk_mcGoodsPane_unuse")
                    && is(code.get(i + 5), PushFalse)
                    && is(code.get(i + 6), SetProperty)) {
                deleteRange(body, i, i + 6);
                hits++;
                break;
            }
        }
        require(hits == 1, "Expected 1 wk_mcGoodsPane_unuse block in loadGoodsPane, found " + hits);
    }

    private void removeSetCapacityCalls() {
        int total = 0;
        for (String name : List.of("pushGoods", "btnItemClick", "btnEquipClick", "btnElseClick", "btnSureClick")) {
            MethodBody body = methodBody(name);
            List<AVM2Instruction> code = body.getCode().code;
            for (int i = code.size() - 4; i >= 0; i--) {
                if (is(code.get(i), GetLocal0)
                        && is(code.get(i + 1), GetLocal0)
                        && is(code.get(i + 2), GetProperty)
                        && (code.get(i + 2).operands[0] == itemCapQName
                            || code.get(i + 2).operands[0] == equipCapQName
                            || code.get(i + 2).operands[0] == elseCapQName)
                        && is(code.get(i + 3), CallPropVoid)
                        && mnName(code.get(i + 3).operands[0]).equals("setCapacity")) {
                    deleteRange(body, i, i + 3);
                    total++;
                }
            }
        }
        require(total == 6, "Expected 6 setCapacity calls removed, got " + total);
    }

    private void removeLefeHandWrites() {
        int total = 0;
        for (String name : List.of("initUI", "initCrtEquip", "putInEquip", "putOutEquip")) {
            MethodBody body = methodBody(name);
            List<AVM2Instruction> code = body.getCode().code;
            for (int i = code.size() - 4; i >= 0; i--) {
                if (is(code.get(i), GetProperty) && mnName(code.get(i).operands[0]).equals("mcBg")
                        && is(code.get(i + 1), GetProperty) && mnName(code.get(i + 1).operands[0]).equals("wk_mcKnapsack_mcLefeHand")
                        && (is(code.get(i + 2), PushFalse) || is(code.get(i + 2), PushTrue))
                        && is(code.get(i + 3), SetProperty) && mnName(code.get(i + 3).operands[0]).equals("visible")) {
                    if (i >= 1 && is(code.get(i - 1), GetLocal0)) {
                        deleteRange(body, i - 1, i + 3);
                        total++;
                        i -= 1;
                    } else {
                        // putOutEquip has getlocal0, pushtrue, iftrue->mcBg, <dead ops>, getproperty mcBg...
                        int start = i - 1;
                        while (start >= 0 && !is(code.get(start), GetLocal0)) start--;
                        require(start >= 0 && i - start <= 15 && is(code.get(start + 1), PushTrue)
                            && is(code.get(start + 2), IfTrue), "Unexpected wk_mcKnapsack_mcLefeHand pattern in " + name);
                        deleteRange(body, start, i + 3);
                        total++;
                        i = start;
                    }
                }
            }
        }
        require(total == 6, "Expected 6 wk_mcKnapsack_mcLefeHand writes removed, got " + total);
    }

    private void removeSortListeners() {
        int total = 0;
        for (String name : List.of("initUI", "configureListeners", "deleteListeners")) {
            MethodBody body = methodBody(name);
            List<AVM2Instruction> code = body.getCode().code;
            for (int i = code.size() - 8; i >= 0; i--) {
                if (is(code.get(i), GetLocal0)
                        && is(code.get(i + 1), GetProperty) && mnName(code.get(i + 1).operands[0]).equals("mcBg")
                        && is(code.get(i + 2), GetProperty) && mnName(code.get(i + 2).operands[0]).equals("wk_mcKnapsack_btnSort")
                        && is(code.get(i + 3), GetLex)
                        && is(code.get(i + 4), GetProperty)
                        && is(code.get(i + 5), GetLocal0)
                        && is(code.get(i + 6), GetProperty) && mnName(code.get(i + 6).operands[0]).equals("btnSortClick")
                        && is(code.get(i + 7), CallPropVoid)) {
                    deleteRange(body, i, i + 7);
                    total++;
                }
            }
        }
        require(total == 3, "Expected 3 btnSort listener calls removed, got " + total);
    }

    private void removeSortFlags() {
        int total = 0;
        for (String name : List.of("initData", "pushGoods", "helmetHandle", "weaponHandle", "shieldHandle", "dressHandle")) {
            MethodBody body = methodBody(name);
            List<AVM2Instruction> code = body.getCode().code;
            for (int i = code.size() - 1; i >= 0; i--) {
                if (is(code.get(i), InitProperty) && mnName(code.get(i).operands[0]).equals("m_bSort")) {
                    // Check normal pattern: getlocal0, pushfalse, initproperty m_bSort
                    if (i >= 2 && is(code.get(i - 2), GetLocal0) && is(code.get(i - 1), PushFalse)) {
                        deleteRange(body, i - 2, i);
                        total++;
                        i -= 2;
                    } else if (i >= 5 && is(code.get(i - 5), GetLocal0)
                            && is(code.get(i - 4), PushTrue)
                            && is(code.get(i - 3), IfTrue)
                            && is(code.get(i - 2), ReturnVoid)
                            && is(code.get(i - 1), PushFalse)) {
                        // shieldHandle obfuscated pattern
                        deleteRange(body, i - 5, i);
                        total++;
                        i -= 5;
                    } else {
                        throw new IllegalStateException("Unexpected m_bSort pattern in " + name);
                    }
                }
            }
        }
        require(total == 7, "Expected 7 m_bSort writes removed, got " + total);
    }

    private void removeDeadPushGoodsSpace() {
        // In pushGoods equip branch, remove the erroneous setGoodsSpace(m_aGoodsCount[1], mCrtItemCapacity)
        // that immediately precedes ++m_aGoodsCount[0] and setGoodsSpace(m_aGoodsCount[0], mCrtEquipCapacity).
        MethodBody body = methodBody("pushGoods");
        List<AVM2Instruction> code = body.getCode().code;
        int hits = 0;
        for (int i = code.size() - 8; i >= 0; i--) {
            if (is(code.get(i), GetLocal0)
                    && is(code.get(i + 1), GetLocal0)
                    && is(code.get(i + 2), GetProperty) && code.get(i + 2).operands[0] == goodsCountQName
                    && is(code.get(i + 3), PushByte) && code.get(i + 3).operands[0] == 1
                    && is(code.get(i + 4), GetProperty) && code.get(i + 4).operands[0] == multinameL
                    && is(code.get(i + 5), GetLocal0)
                    && is(code.get(i + 6), GetProperty) && code.get(i + 6).operands[0] == itemCapQName
                    && is(code.get(i + 7), CallPropVoid) && code.get(i + 7).operands[0] == setGoodsSpaceQName) {
                // Only remove the first one (before pushshort 1000..2000 item branch; the second is in the item branch!)
                if (i < 90) {
                    deleteRange(body, i, i + 7);
                    hits++;
                }
            }
        }
        require(hits == 1, "Expected 1 dead setGoodsSpace in pushGoods equip branch, got " + hits);
    }

    private void removeTraits() {
        removeTraitsFrom("Knapsack", Set.of("btnSortClick", "sortFunction", "m_bSort", "dun", "hasi", "mDun", "mHasi", "setCapacity"));
        removeTraitsFrom("mcKnapsack", Set.of("wk_mcKnapsack_btnSort", "wk_mcKnapsack_txtDun", "wk_mcKnapsack_txtHasi", "wk_mcKnapsack_mcLefeHand"));
        removeTraitsFrom("mcGoodsPane", Set.of("wk_mcGoodsPane_unuse"));
    }

    private void removeTraitsFrom(String className, Set<String> names) {
        InstanceInfo info = findInstance(className);
        int removed = 0;
        for (Iterator<Trait> it = info.instance_traits.traits.iterator(); it.hasNext(); ) {
            Trait tr = it.next();
            if (names.contains(mnName(tr.name_index))) {
                it.remove();
                removed++;
            }
        }
        require(removed == names.size(),
            "Expected " + names.size() + " traits removed from " + className + ", got " + removed);
    }

    private void apply() {
        patchSpritesAndShapes();
        patchKnapsackCode();
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("Expected input and output game.swf paths");
        Path input = Path.of(args[0]).toRealPath();
        Path output = Path.of(args[1]).toAbsolutePath().normalize();
        require(!input.equals(output) && (!Files.exists(output) || !Files.isSameFile(input, output)),
            "Choose an output distinct from the input SWF");

        SWF swf;
        try (InputStream stream = Files.newInputStream(input)) {
            swf = new SWF(stream, false);
        }
        ABCContainerTag abcTag = swf.getAbcList().stream()
            .filter(t -> t.getABC().instance_info.stream().anyMatch(info -> {
                var abc = t.getABC();
                int ni = abc.constants.getMultiname(info.name_index).name_index;
                return ni > 0 && "Knapsack".equals(abc.constants.getString(ni));
            }))
            .findFirst().orElseThrow();
        new PatchKnapsackUI(swf, abcTag.getABC()).apply();
        ((Tag) abcTag).setModified(true);

        Files.createDirectories(output.getParent());
        try (OutputStream stream = Files.newOutputStream(output)) {
            swf.saveTo(stream);
        }
        System.out.println("Patched Knapsack UI: " + output);
    }
}
