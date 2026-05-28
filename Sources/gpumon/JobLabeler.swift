import Foundation

/// Turns a process (nvidia-smi process name + /proc cmdline + cwd) into a short, human label
/// like "ComfyUI", "vLLM", "llama.cpp", or — for custom jobs — a tidied project/script name.
enum JobLabeler {
    /// Known frameworks, matched as substrings of the combined cmdline/cwd/name (lowercased).
    /// Order matters: more specific entries first.
    private static let frameworks: [(needle: String, label: String)] = [
        ("comfyui", "ComfyUI"),
        ("stable-diffusion-webui", "A1111"),
        ("/sd-webui", "A1111"),
        ("forge", "Forge"),
        ("simpletuner", "SimpleTuner"),
        ("ai-toolkit", "ai-toolkit"),
        ("ai_toolkit", "ai-toolkit"),
        ("kohya", "kohya"),
        ("sd-scripts", "sd-scripts"),
        ("axolotl", "Axolotl"),
        ("unsloth", "Unsloth"),
        ("llama-server", "llama.cpp"),
        ("llama_cpp", "llama.cpp"),
        ("llama.cpp", "llama.cpp"),
        ("text-generation-inference", "TGI"),
        ("tabbyapi", "TabbyAPI"),
        ("exllama", "ExLlama"),
        ("sglang", "SGLang"),
        ("vllm", "vLLM"),
        ("ollama", "Ollama"),
        ("deepspeed", "DeepSpeed"),
    ]

    /// Path components that don't identify a job on their own.
    private static let generic: Set<String> = [
        "", "/", "home", "root", "tmp", "usr", "opt", "mnt", "var", "srv",
        "src", "scripts", "workspace", "work", "code", "repos", "projects",
        "venv", ".venv", "env", "bin", "python", "python3", "brian",
    ]

    static func label(processName: String, cmdline: String, cwd: String) -> String {
        let cmd = cmdline.trimmingCharacters(in: .whitespacesAndNewlines)
        let hay = (cmd + " " + cwd + " " + processName).lowercased()

        for fw in frameworks where hay.contains(fw.needle) {
            return fw.label
        }

        // Custom jobs: the user said the cwd is usually the right thing to show.
        if let proj = projectName(from: cwd) { return cap(proj) }
        if let script = scriptName(from: cmd) { return cap(script) }

        let pn = processName.trimmingCharacters(in: .whitespaces)
        return pn.isEmpty || pn == "[Not Found]" ? "" : cap(pn)
    }

    /// Last meaningful path component of the cwd, e.g. /home/brian/experiments/exp42 -> "exp42".
    private static func projectName(from cwd: String) -> String? {
        let parts = cwd.split(separator: "/").map(String.init)
        for part in parts.reversed() where !generic.contains(part.lowercased()) {
            return part
        }
        return nil
    }

    /// Derive a name from a python entrypoint: "python train.py" -> "train", "-m pkg.mod" -> "mod".
    private static func scriptName(from cmd: String) -> String? {
        let tokens = cmd.split(separator: " ").map(String.init)
        if let i = tokens.firstIndex(of: "-m"), i + 1 < tokens.count {
            return tokens[i + 1].split(separator: ".").last.map(String.init)
        }
        if let py = tokens.first(where: { $0.hasSuffix(".py") }) {
            let base = py.split(separator: "/").last.map(String.init) ?? py
            return String(base.dropLast(3)) // strip ".py"
        }
        return nil
    }

    private static func cap(_ s: String, max: Int = 20) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
