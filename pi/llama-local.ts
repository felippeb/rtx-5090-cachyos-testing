import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("llama-local", {
    name: "llama.cpp Local",
    baseUrl: "http://localhost:10500/v1",
    apiKey: "local",
    api: "openai-completions",
    models: [
      {
        id: "qwen3.6-27b-mtp-131k",
        name: "llama.cpp | Qwen3.6-27B MTP (131K)",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 131072,
        maxTokens: 16384,
        compat: {
          maxTokensField: "max_tokens",
          modelId: "Qwen3.6-27B-UD-Q4_K_XL",
        },
      },
      {
        id: "qwen3.6-35b-a3b-mtp-131k",
        name: "llama.cpp | Qwen3.6-35B-A3B MTP (131K)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 131072,
        maxTokens: 16384,
        compat: {
          maxTokensField: "max_tokens",
          modelId: "Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL",
        },
      },
      {
        id: "gemma4-31b-mtp-131k",
        name: "llama.cpp | Gemma 4 31B MTP (131K)",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 131072,
        maxTokens: 8192,
        compat: {
          maxTokensField: "max_tokens",
          modelId: "gemma-4-31B-it-assistant.Q4_K_M",
        },
      },
    ],
  });
}
