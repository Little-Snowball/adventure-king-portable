import com.jpexs.decompiler.flash.SWF;
import com.jpexs.decompiler.flash.abc.ABC;
import com.jpexs.decompiler.flash.abc.types.MethodBody;
import com.jpexs.decompiler.flash.tags.ABCContainerTag;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HexFormat;

// Reads original method bodies by class and name without the disassembler's branch normalization.
public class ReadMethodBodies {
    public static void main(String[] args) throws Exception {
        try (var input = Files.newInputStream(Path.of(args[0]))) {
            SWF swf = new SWF(input, false);
            for (int i = 1; i < args.length; i++) {
                String[] names = args[i].split(":", 2);
                MethodBody body = null;
                for (ABCContainerTag container : swf.getAbcList()) {
                    ABC abc = container.getABC();
                    MethodBody candidate = abc.findBodyByClassAndName(names[0], names[1]);
                    if (candidate != null) {
                        if (body != null) throw new IllegalStateException("Duplicate AVM2 method: " + args[i]);
                        body = candidate;
                    }
                }
                if (body == null) throw new IllegalStateException("Missing AVM2 method: " + args[i]);
                if (body.exceptions.length != 0) throw new IllegalStateException("Unexpected exception handlers: " + args[i]);
                System.out.printf("%s\t%d\t%s%n", args[i], body.method_info,
                                  HexFormat.of().formatHex(body.getCodeBytes()));
            }
        }
    }
}
