// Decompile every function in the program into one C file, in parallel.
// Usage (headless): -postScript DecompileAll.java <output.c>
// Each function is prefixed with "// FUNCTION <name> @ <address> rva=<rva>".
//@category Conquest

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.decompiler.parallel.DecompileConfigurer;
import ghidra.app.decompiler.parallel.DecompilerCallback;
import ghidra.app.decompiler.parallel.ParallelDecompiler;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.util.task.TaskMonitor;

import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

public class DecompileAll extends GhidraScript {
	@Override
	public void run() throws Exception {
		String out = getScriptArgs()[0];
		long base = currentProgram.getImageBase().getOffset();

		List<Function> functions = new ArrayList<>();
		currentProgram.getFunctionManager().getFunctions(true).forEach(functions::add);
		println("decompiling " + functions.size() + " functions");

		DecompileConfigurer configurer = decompiler -> {
			decompiler.toggleCCode(true);
			decompiler.toggleSyntaxTree(false);
			decompiler.setSimplificationStyle("decompile");
		};
		DecompilerCallback<String> callback = new DecompilerCallback<>(currentProgram, configurer) {
			@Override
			public String process(DecompileResults results, TaskMonitor monitor) {
				Function f = results.getFunction();
				long addr = f.getEntryPoint().getOffset();
				String header = String.format("// FUNCTION %s @ %x rva=%x%n", f.getName(), addr, addr - base);
				if (results.getDecompiledFunction() == null) {
					return header + "// (decompilation failed: " + results.getErrorMessage() + ")\n\n";
				}
				return header + results.getDecompiledFunction().getC() + "\n";
			}
		};
		callback.setTimeout(60);

		List<String> results = ParallelDecompiler.decompileFunctions(callback, functions, monitor);
		callback.dispose();

		// stable output order by address
		Map<Long, String> ordered = new TreeMap<>();
		for (String r : results) {
			int at = r.indexOf(" @ ");
			long addr = Long.parseUnsignedLong(r.substring(at + 3, r.indexOf(' ', at + 3)), 16);
			ordered.put(addr, r);
		}
		try (PrintWriter w = new PrintWriter(out, "UTF-8")) {
			for (String r : ordered.values()) {
				w.print(r);
			}
		}
		println("wrote " + ordered.size() + " functions to " + out);
	}
}
