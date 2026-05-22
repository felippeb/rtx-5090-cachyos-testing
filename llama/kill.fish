#!/usr/bin/env fish
# Quick-kill all inference servers and free the GPU
# Add to config.fish: alias killllama='~/.local/bin/kill-llama.fish'

for svc in llama-server llama-server-turbo llama-server-gemma4 llama-server-gemma4-turbo llama-server-qwen35b llama-server-qwen35b-turbo llama-server-qwen3-14b llama-server-e4b llama-server-mtp llama-server-mtp-131k vllm-qwen3.6-27b-nvfp4 vllm-qwen3.6-27b-nvfp4-turbo
    if systemctl is-active --quiet "$svc" 2>/dev/null
        echo "Killing $svc..."
        systemctl --user stop "$svc"
    end
end

echo "GPU freed."
