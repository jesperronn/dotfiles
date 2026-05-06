# M5 Max Local AI Development Guide: Ollama & VS Code

This guide provides the definitive setup and troubleshooting steps for running high-precision local LLMs (like Qwen 3.6 35B) within VS Code using the Continue extension.

## 1. System Architecture & Logic
The M5 Max with 128GB RAM allows for "high-precision" (BF16/FP16) models. To ensure a stable integration between Ollama and VS Code, we use a **System Message Tools** strategy.

* **The Problem:** Local models often stream conversational text (preambles) before outputting tool calls. Ollama’s native JSON parser is rigid and fails if any non-JSON text is present, leading to "Missing Arguments" errors.
* **The Solution:** We bypass Ollama’s native tool parser by enabling `onlyUseSystemMessageTools`. This forces Continue to inject tool definitions into the text prompt and use its own robust Regex parser to "scrape" edits and commands from the model's response.
* **Configuration:** All model definitions, role assignments (chat, edit, autocomplete), and experimental flags are managed in the `config.yaml` file located in the same folder as this guide.

## 2. Setup Instructions
1.  **Ollama Preparation:** Pull the required models via terminal:
    * `ollama pull qwen3.6:35b-a3b-coding-bf16` (Primary Agent)
    * `ollama pull qwen3.5:9b` (Autocomplete)
    * `ollama pull nomic-embed-text` (Embeddings)
2.  **Continue Extension:** Install the Continue extension in VS Code.
3.  **Config Sync:** Ensure your `~/.continue/config.yaml` matches the high-precision definitions (see the local `config.yaml` for exact syntax).
4.  **Experimental Toggles:** * Open Continue Settings (Gear Icon) -> **Experimental**.
    * Enable **"Only use system message tools"**.
    * Enable **"Enable experimental tools"**.

## 3. Troubleshooting & Debugging
If the Agent fails to edit files or enters a loop, use the following consoles to find the root cause:

### Viewing the "Continue Console"
To see the raw communication between the LLM and the extension (including the exact text the model is generating before it is parsed):
1.  Press `Cmd + Shift + U` (macOS) or `Ctrl + Shift + U` (Windows/Linux).
2.  In the **Output** panel dropdown on the right, select **Continue - Language Server**.
3.  This is where you will see if the model is hallucinating "SUGGESTED EDIT" headers or failing to follow the tool schema.

### Viewing the VS Code Developer Console
To debug extension crashes, AST (Abstract Syntax Tree) tracker errors, or file system permission issues:
1.  Go to the top menu: **Help > Toggle Developer Tools**.
2.  Select the **Console** tab.
3.  Look for red error blocks or "Document not found in AST tracker" messages.

### Common Error Resolutions
* **"Arguments `filepath` and `changes` are required":** This confirms the parser failed. Ensure `onlyUseSystemMessageTools` is set to `true` in both the UI and `config.yaml`.
* **"Document not found in AST tracker":** Usually a symptom of a failed tool call. Ensure the file you are editing is open in an active tab and that you have opened the **Folder** (Workspace) in VS Code, not just a single file.
* **No "Thinking" showing up:** Raise the `temperature` to `0.6` in `config.yaml`. Greedy decoding (`0.0`) often causes the model to skip its reasoning steps.

## 4. Roadmap & TBD Areas

### Agentic Features (TBD)
* **Auto-Approval Implementation:** Currently, Continue requires a manual click to approve every file edit or terminal command. We are monitoring [Issue #12172](https://github.com/continuedev/continue/issues/12172) for the implementation of an "Always Allow" or "Auto-Approve" policy similar to Cursor.

### Testing & Validation
* **Embeddings Strategy:** We need to verify the performance of `nomic-embed-text` vs. the 128GB RAM overhead. Testing is required to see if a larger embedding model provides better RAG (Retrieval-Augmented Generation) results for this specific codebase.
* **Autocomplete Optimization:** We need to benchmark the `qwen3.5:9b` model to ensure it provides sub-100ms latency for tab-completions without interfering with the primary 35B chat model's VRAM.

### Infrastructure
* **Debug Logging Fix:** Currently, standard file logging to `~/.continue/logs/core.log` can be inconsistent. We need to identify a method to force persistent debug logging to disk for easier long-term troubleshooting.

## 5. Drill-Down Resources
* [Continue Documentation: Ollama Guide](https://docs.continue.dev/guides/ollama-guide)
* [Ollama API: OpenAI Compatibility](https://docs.ollama.com/api/openai)
* [YAML Migration Reference](https://docs.continue.dev/reference/yaml-migration)
