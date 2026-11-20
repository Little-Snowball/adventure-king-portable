import com.jpexs.decompiler.flash.SWF;
import com.jpexs.decompiler.flash.abc.ABC;
import com.jpexs.decompiler.flash.abc.avm2.AVM2Code;
import com.jpexs.decompiler.flash.abc.avm2.instructions.AVM2Instruction;
import com.jpexs.decompiler.flash.abc.types.MethodBody;
import com.jpexs.decompiler.flash.abc.types.Multiname;
import com.jpexs.decompiler.flash.abc.types.Namespace;
import com.jpexs.decompiler.flash.tags.ABCContainerTag;
import com.jpexs.decompiler.flash.tags.Tag;

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;

import static com.jpexs.decompiler.flash.abc.avm2.instructions.AVM2Instructions.*;

/** Small AVM2 patch for the obfuscated fight class. Preserves unrelated game bytecode. */
public final class PatchSkillInput {
    private static final String FIGHT = "fightMain";
    private static final String MARKER = "__portableHeldSkillKeys";
    private static final int INITIAL_DELAY = 6; // 250 ms at the game's native 24 FPS.
    private final ABC abc;
    private final int publicNamespace;
    private final int runtimePublicName;
    private final int heldSkills;
    private final int keyObj;
    private final int keyArr;

    private PatchSkillInput(ABC abc) {
        this.abc = abc;
        var fields = abc.instance_info.stream()
                .filter(info -> name(info.name_index).equals(FIGHT)).findFirst().orElseThrow()
                .instance_traits.traits;
        keyObj = fields.stream().filter(trait -> name(trait.name_index).equals("keyObj"))
                .findFirst().orElseThrow().name_index;
        keyArr = fields.stream().filter(trait -> name(trait.name_index).equals("keyArr"))
                .findFirst().orElseThrow().name_index;
        require(abc.constants.getStringId(MARKER, false) < 1, "Skill input patch is already present");
        publicNamespace = abc.constants.getNamespaceId(Namespace.KIND_PACKAGE, "", 0, false);
        runtimePublicName = abc.constants.getMultinameId(Multiname.createMultinameL(false,
                abc.constants.getNamespaceSetId(new int[] { publicNamespace }, true)), true);
        heldSkills = member(MARKER);
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new IllegalStateException(message);
    }

    private String name(int multiname) {
        return abc.constants.getString(abc.constants.getMultiname(multiname).name_index);
    }

    private int member(String name) {
        return abc.constants.getMultinameId(Multiname.createQName(false,
                abc.constants.getStringId(name, true), publicNamespace), true);
    }

    private static AVM2Instruction instruction(int opcode, int... operands) {
        return new AVM2Instruction(0, opcode, operands);
    }

    private static boolean is(AVM2Instruction instruction, int opcode) {
        return instruction.definition == AVM2Code.instructionSet[opcode];
    }

    private static int branchTarget(AVM2Instruction instruction, int operand) {
        int origin = Math.toIntExact(instruction.getAddress());
        if (!is(instruction, LookupSwitch)) origin += instruction.getBytesLength();
        return origin + instruction.operands[operand];
    }

    private static void recordTarget(Map<Integer, AVM2Instruction> addresses, AVM2Instruction branch,
                                     int operand, List<AVM2Instruction> targets) {
        var target = addresses.get(branchTarget(branch, operand));
        require(target != null, "Original branch targets a non-instruction address");
        targets.add(target);
    }

    /** Guard against inserting at original branch targets and make sure FFDec preserved switch edges. */
    private static Map<AVM2Instruction, List<AVM2Instruction>> originalBranches(MethodBody body) {
        var result = new IdentityHashMap<AVM2Instruction, List<AVM2Instruction>>();
        var addresses = new HashMap<Integer, AVM2Instruction>();
        for (var instruction : body.getCode().code) {
            addresses.put(Math.toIntExact(instruction.getAddress()), instruction);
        }
        for (var instruction : body.getCode().code) {
            if (is(instruction, LookupSwitch)) {
                var targets = new ArrayList<AVM2Instruction>();
                recordTarget(addresses, instruction, 0, targets);
                for (int index = 2; index < instruction.operands.length; index++) {
                    recordTarget(addresses, instruction, index, targets);
                }
                result.put(instruction, targets);
            } else if (instruction.definition.instructionCode >= IfNLt
                    && instruction.definition.instructionCode <= IfStrictNe) {
                var targets = new ArrayList<AVM2Instruction>();
                recordTarget(addresses, instruction, 0, targets);
                result.put(instruction, targets);
            }
        }
        return result;
    }

    private static final class Block {
        final List<AVM2Instruction> code = new ArrayList<>();
        final Map<String, List<AVM2Instruction>> fixups = new HashMap<>();
        final Map<String, Integer> labels = new HashMap<>();

        void emit(int opcode, int... operands) { code.add(instruction(opcode, operands)); }
        void branch(int opcode, String label) {
            var branch = instruction(opcode, 0);
            code.add(branch);
            fixups.computeIfAbsent(label, ignored -> new ArrayList<>()).add(branch);
        }
        void mark(String label) {
            require(labels.put(label, code.size()) == null, "Duplicate AVM2 label " + label);
        }
        void insert(MethodBody body, int index) {
            var existing = body.getCode().code.get(index);
            var original = originalBranches(body);
            require(original.values().stream().noneMatch(targets -> targets.contains(existing)),
                    "Patch point is a branch destination");
            body.insertAll(index, code);
            for (var entry : fixups.entrySet()) {
                var target = body.getCode().code.get(index + labels.get(entry.getKey()));
                for (var branch : entry.getValue()) {
                    int offset = Math.toIntExact(target.getAddress() - branch.getAddress() - branch.getBytesLength());
                    branch.setOperands(new int[] { offset }, body.getCode(), body);
                }
            }
            original.forEach((branch, targets) -> {
                for (int j = 0; j < targets.size(); j++) {
                    int operand = is(branch, LookupSwitch) && j > 0 ? j + 1 : j;
                    require(branchTarget(branch, operand) == targets.get(j).getAddress(),
                            "An original AVM2 branch changed its destination");
                }
            });
            body.markOffsets();
            body.setCode(body.getCode());
        }
    }

    private MethodBody body(String method) {
        var body = abc.findBodyByClassAndName(FIGHT, method);
        require(body != null, "Expected fight method: " + method);
        return body;
    }

    private int singleMemberInstruction(MethodBody body, int opcode, String member) {
        int match = -1;
        var instructions = body.getCode().code;
        for (int index = 0; index < instructions.size(); index++) {
            var instruction = instructions.get(index);
            if (is(instruction, opcode) && name(instruction.operands[0]).equals(member)) {
                require(match < 0, "Ambiguous AVM2 anchor for " + member);
                match = index;
            }
        }
        require(match >= 0, "Missing AVM2 anchor for " + member);
        return match;
    }

    private void getKeyState(Block block) {
        block.emit(GetLocal0);
        block.emit(GetProperty, keyObj);
    }

    private void getHeldSkills(Block block) {
        getKeyState(block);
        block.emit(GetProperty, heldSkills);
    }

    private void clearHeldSkills(Block block) {
        getKeyState(block);
        block.emit(NewObject, 0);
        block.emit(SetProperty, heldSkills);
    }

    private void resetHeldSkills(MethodBody body, int at) {
        var block = new Block();
        clearHeldSkills(block);
        block.insert(body, at);
    }

    private void patchDown() {
        var body = body("keyDownmethod");
        var calls = new ArrayList<Integer>();
        var instructions = body.getCode().code;
        for (int i = 0; i < instructions.size(); i++) {
            var ins = instructions.get(i);
            if (is(ins, CallPropVoid) && name(ins.operands[0]).equals("fastSkill")) {
                require(ins.operands[1] == 1, "Unexpected fastSkill invocation");
                calls.add(i);
            } else if (is(ins, SetProperty) && "runskill".equals(name(ins.operands[0]))) {
                require(is(instructions.get(i - 1), PushTrue), "Expected primary skill key-down");
                calls.add(i);
            }
        }
        require(calls.size() == 10, "Expected one primary skill and four quick skills per player");
        for (int i = calls.size() - 1; i >= 0; i--) {
            // The original receiver and call argument or assignment value stay on the stack.
            // Only an original accepted key-down path may begin a held repeat.
            var markHeld = new Block();
            getHeldSkills(markHeld);
            markHeld.emit(GetLocal1);
            markHeld.emit(GetProperty, member("keyCode"));
            markHeld.emit(GetLocal0);
            markHeld.emit(GetProperty, member("allTimer"));
            markHeld.emit(PushByte, INITIAL_DELAY);
            markHeld.emit(AddI);
            markHeld.emit(SetProperty, runtimePublicName);
            markHeld.insert(body, calls.get(i));
        }
        body.max_stack = Math.max(body.max_stack, 6);
    }

    private void patchUp() {
        var body = body("keyUpmethod");
        // Clear all held skills on an actual pause-state toggle, without affecting other input flags.
        int toggle = singleMemberInstruction(body, InitProperty, "gameRun");
        resetHeldSkills(body, toggle + 1);
        var stopRepeat = new Block();
        getHeldSkills(stopRepeat);
        stopRepeat.emit(GetLocal1);
        stopRepeat.emit(GetProperty, member("keyCode"));
        stopRepeat.emit(DeleteProperty, runtimePublicName);
        stopRepeat.emit(Pop);
        stopRepeat.insert(body, 2); // After getlocal0/pushscope, before original key-up processing.
    }

    private void appendPlayer(Block block, int player, int firstSlot) {
        String endPlayer = "endPlayer" + player;
        if (player == 2) {
            block.emit(GetLocal0);
            block.emit(GetProperty, member("playerNum"));
            block.emit(PushByte, 2);
            block.branch(IfNe, endPlayer);
        }
        block.emit(GetLocal0);
        block.emit(GetProperty, member("mainActor" + player));
        block.emit(SetLocal2);
        block.emit(GetLocal2);
        block.branch(IfFalse, endPlayer);
        block.emit(GetLocal2);
        block.emit(GetProperty, member("thisCurHp"));
        block.emit(PushByte, 0);
        block.branch(IfNGt, endPlayer);
        for (int slot = 1; slot <= 4; slot++) {
            String endSlot = "endSlot" + player + "_" + slot;
            skipUnlessHeld(block, firstSlot + slot - 1, endSlot);
            block.emit(GetLocal2);
            block.emit(PushString, abc.constants.getStringId(Integer.toString(slot), true));
            block.emit(CallPropVoid, member("fastSkill"), 1);
            block.mark(endSlot);
        }
        // The primary skill is selected by dealOnce, where normal attack takes precedence.
        skipUnlessHeld(block, firstSlot - 1, endPlayer);
        block.emit(GetLocal2);
        block.emit(GetProperty, member("commond"));
        block.emit(GetProperty, member("runattack"));
        block.branch(IfTrue, endPlayer);
        block.emit(GetLocal2);
        block.emit(GetProperty, member("nowCommond"));
        block.emit(PushString, abc.constants.getStringId("skill", true));
        block.branch(IfStrictNe, endPlayer);
        block.emit(GetLocal2);
        block.emit(CallPropVoid, member("skill"), 0);
        block.mark(endPlayer);
    }

    private void skipUnlessHeld(Block block, int keyIndex, String skip) {
        getHeldSkills(block);
        block.emit(GetLocal0);
        block.emit(GetProperty, keyArr);
        block.emit(PushByte, keyIndex);
        block.emit(GetProperty, runtimePublicName);
        block.emit(GetProperty, runtimePublicName);
        block.emit(GetLocal0);
        block.emit(GetProperty, member("allTimer"));
        // A missing key gives undefined, so negated <= also skips an unheld skill.
        block.branch(IfNLe, skip);
    }

    private void patchUpdate() {
        var body = body("dealGame");
        int checkSite = singleMemberInstruction(body, CallPropVoid, "checkMASite");
        require(is(body.getCode().code.get(checkSite - 1), GetLocal0), "Unexpected battle update layout");
        var block = new Block();
        block.emit(GetLocal0);
        block.emit(GetProperty, member("overMc"));
        block.branch(IfTrue, "finish");
        appendPlayer(block, 1, 7);
        appendPlayer(block, 2, 19);
        // Original method has killed this temporary local immediately before the splice.
        block.emit(Kill, 2);
        block.mark("finish");
        block.insert(body, checkSite - 1);
        body.max_stack = Math.max(body.max_stack, 4);
    }

    private void apply() {
        var constructor = abc.findBodyInstanceInitializerByClass(FIGHT);
        var instructions = constructor.getCode().code;
        int afterSuper = 0;
        while (afterSuper < instructions.size() && !is(instructions.get(afterSuper++), ConstructSuper)) {}
        require(afterSuper < instructions.size(), "Expected fight constructor superclass call");
        resetHeldSkills(constructor, afterSuper);
        resetHeldSkills(body("missingStage"), 2); // Before original focus-loss handling.
        patchDown();
        patchUp();
        patchUpdate();
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("Expected input and output game.swf paths");
        Path input = Path.of(args[0]).toRealPath();
        Path output = Path.of(args[1]).toAbsolutePath().normalize();
        require(!input.equals(output) && (!Files.exists(output) || !Files.isSameFile(input, output)),
                "Choose an output distinct from the input SWF");
        SWF movie;
        try (InputStream stream = Files.newInputStream(input)) {
            movie = new SWF(stream, false);
        }
        ABCContainerTag tag = movie.getAbcList().stream().filter(candidate -> {
            var abc = candidate.getABC();
            return abc.findBodyByClassAndName(FIGHT, "dealGame") != null;
        }).findFirst().orElseThrow();
        new PatchSkillInput(tag.getABC()).apply();
        ((Tag) tag).setModified(true);
        Files.createDirectories(output.getParent());
        try (OutputStream stream = Files.newOutputStream(output)) {
            movie.saveTo(stream);
        }
        System.out.println("Patched fightMain skill input: " + output);
    }
}
