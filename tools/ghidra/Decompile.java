// Decompile selected functions and their callees to a given depth.
// Usage (headless): -postScript Decompile.java <output.c> <depth> <rva> [<rva> ...]
// RVAs are hex, relative to the image base.
//@category Conquest

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

import java.io.PrintWriter;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.LinkedHashMap;
import java.util.Map;

public class Decompile extends GhidraScript {
	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		String out = args[0];
		int maxDepth = Integer.parseInt(args[1]);
		long base = currentProgram.getImageBase().getOffset();

		DecompInterface decompiler = new DecompInterface();
		decompiler.openProgram(currentProgram);

		Map<Function, Integer> seen = new LinkedHashMap<>();
		Deque<Function> queue = new ArrayDeque<>();
		for (int i = 2; i < args.length; i++) {
			Address a = currentProgram.getImageBase().add(Long.parseUnsignedLong(args[i].replace("0x", ""), 16));
			Function f = getFunctionContaining(a);
			if (f == null) {
				println("no function at " + a);
				continue;
			}
			if (!seen.containsKey(f)) {
				seen.put(f, 0);
				queue.add(f);
			}
		}

		try (PrintWriter w = new PrintWriter(out, "UTF-8")) {
			while (!queue.isEmpty()) {
				Function f = queue.poll();
				int depth = seen.get(f);
				long addr = f.getEntryPoint().getOffset();
				w.printf("// FUNCTION %s @ %x rva=%x depth=%d%n", f.getName(), addr, addr - base, depth);
				DecompileResults r = decompiler.decompileFunction(f, 60, monitor);
				w.println(r.getDecompiledFunction() != null ? r.getDecompiledFunction().getC() : "// failed");
				if (depth < maxDepth) {
					for (Function callee : f.getCalledFunctions(monitor)) {
						if (!seen.containsKey(callee)) {
							seen.put(callee, depth + 1);
							queue.add(callee);
						}
					}
				}
			}
		}
		decompiler.dispose();
		println("wrote " + seen.size() + " functions to " + out);
	}
}
