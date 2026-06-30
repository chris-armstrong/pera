((providers
  (((name moonshotai) (protocol openai-completions)
    (api_key_env (MOONSHOT_API_KEY)) (api https://api.moonshot.ai/v1)
    (compat
     ((reasoning_field reasoning_content) (max_tokens_field max_tokens)
      (require_tool_result_name false)
      (enable_thinking_field enable_thinking)))
    (models
     (((name kimi-k2-0905-preview) (context_window 262144)
       (max_tokens 262144)
       (thinking ((budget_medium 8000) (budget_high 32000)))
       (cost
        ((input_per_mtok 0.6) (output_per_mtok 2.5)
         (cache_read_per_mtok 0.15)))))))
   ((name zhipuai) (protocol openai-completions)
    (api_key_env (ZHIPU_API_KEY)) (api https://open.bigmodel.cn/api/paas/v4)
    (compat ((reasoning_field reasoning_content)))
    (models
     (((name glm-5.1) (context_window 200000) (max_tokens 131072)
       (cost
        ((input_per_mtok 6) (output_per_mtok 24) (cache_read_per_mtok 1.3)
         (cache_write_per_mtok 0))))
      ((name glm-5.2) (context_window 1000000) (max_tokens 131072)
       (cost
        ((input_per_mtok 1.4) (output_per_mtok 4.4)
         (cache_read_per_mtok 0.26) (cache_write_per_mtok 0))))
      ((name glm-5) (context_window 204800) (max_tokens 131072)
       (cost
        ((input_per_mtok 1) (output_per_mtok 3.2) (cache_read_per_mtok 0.2)
         (cache_write_per_mtok 0))))
      ((name glm-4.7-flash) (context_window 200000) (max_tokens 131072)
       (cost
        ((input_per_mtok 0) (output_per_mtok 0) (cache_read_per_mtok 0)
         (cache_write_per_mtok 0)))))))
   ((name mistral) (protocol openai-completions)
    (api_key_env (MISTRAL_API_KEY))
    (models
     (((name codestral-latest) (context_window 256000) (max_tokens 4096)
       (cost ((input_per_mtok 0.3) (output_per_mtok 0.9))))
      ((name mistral-large-latest) (context_window 262144)
       (max_tokens 262144)
       (cost ((input_per_mtok 0.5) (output_per_mtok 1.5))))
      ((name mistral-small-latest) (context_window 256000)
       (max_tokens 256000)
       (cost ((input_per_mtok 0.15) (output_per_mtok 0.6))))
      ((name devstral-latest) (context_window 262144) (max_tokens 262144)
       (cost ((input_per_mtok 0.4) (output_per_mtok 2)))))))
   ((name openai) (protocol openai-completions)
    (api_key_env (OPENAI_API_KEY))
    (compat
     ((max_tokens_field max_completion_tokens)
      (require_tool_result_name false)))
    (models
     (((name o3) (context_window 200000) (max_tokens 100000)
       (cost
        ((input_per_mtok 2) (output_per_mtok 8) (cache_read_per_mtok 0.5))))
      ((name gpt-4o) (context_window 128000) (max_tokens 16384)
       (cost
        ((input_per_mtok 2.5) (output_per_mtok 10)
         (cache_read_per_mtok 1.25)))))))
   ((name groq) (protocol openai-completions) (api_key_env (GROQ_API_KEY))
    (models
     (((name llama-3.3-70b-versatile) (context_window 131072)
       (max_tokens 32768)
       (cost ((input_per_mtok 0.59) (output_per_mtok 0.79))))
      ((name llama-3.1-8b-instant) (context_window 131072)
       (max_tokens 131072)
       (cost ((input_per_mtok 0.05) (output_per_mtok 0.08))))
      ((name meta-llama/llama-4-scout-17b-16e-instruct)
       (context_window 131072) (max_tokens 8192)
       (cost ((input_per_mtok 0.11) (output_per_mtok 0.34))))
      ((name qwen/qwen3-32b) (context_window 131072) (max_tokens 40960)
       (cost ((input_per_mtok 0.29) (output_per_mtok 0.59)))))))
   ((name ollama-cloud) (protocol openai-completions)
    (api_key_env (OLLAMA_API_KEY)) (api https://ollama.com/v1)
    (compat ((reasoning_field reasoning_content)))
    (models
     (((name deepseek-v4-flash) (context_window 1048576)
       (max_tokens 1048576))
      ((name minimax-m2.5) (context_window 204800) (max_tokens 131072))
      ((name glm-4.7) (context_window 202752) (max_tokens 131072)))))
   ((name anthropic) (protocol anthropic) (api_key_env (ANTHROPIC_API_KEY))
    (models
     (((name claude-haiku-4-5-20251001) (context_window 200000)
       (max_tokens 64000)
       (thinking ((budget_medium 8000) (budget_high 32000)))
       (cost
        ((input_per_mtok 1) (output_per_mtok 5) (cache_read_per_mtok 0.1)
         (cache_write_per_mtok 1.25))))
      ((name claude-sonnet-4-6) (context_window 1000000) (max_tokens 64000)
       (thinking ((budget_medium 8000) (budget_high 32000)))
       (cost
        ((input_per_mtok 3) (output_per_mtok 15) (cache_read_per_mtok 0.3)
         (cache_write_per_mtok 3.75)))))))
   ((name togetherai) (protocol openai-completions)
    (api_key_env (TOGETHER_API_KEY))
    (models
     (((name meta-llama/Llama-3.3-70B-Instruct-Turbo) (context_window 131072)
       (max_tokens 131072)
       (cost ((input_per_mtok 0.88) (output_per_mtok 0.88))))
      ((name moonshotai/Kimi-K2.6) (context_window 262144)
       (max_tokens 131000)
       (cost
        ((input_per_mtok 1.2) (output_per_mtok 4.5)
         (cache_read_per_mtok 0.2)))))))
   ((name deepseek) (protocol openai-completions)
    (api_key_env (DEEPSEEK_API_KEY)) (api https://api.deepseek.com)
    (compat ((reasoning_field reasoning_content)))
    (models
     (((name deepseek-v4-flash) (context_window 1000000) (max_tokens 384000)
       (cost
        ((input_per_mtok 0.14) (output_per_mtok 0.28)
         (cache_read_per_mtok 0.0028))))
      ((name deepseek-v4-pro) (context_window 1000000) (max_tokens 384000)
       (cost
        ((input_per_mtok 0.435) (output_per_mtok 0.87)
         (cache_read_per_mtok 0.003625))))
      ((name deepseek-reasoner) (context_window 1000000) (max_tokens 384000)
       (cost
        ((input_per_mtok 0.14) (output_per_mtok 0.28)
         (cache_read_per_mtok 0.0028))))
      ((name deepseek-chat) (context_window 1000000) (max_tokens 384000)
       (cost
        ((input_per_mtok 0.14) (output_per_mtok 0.28)
         (cache_read_per_mtok 0.0028))))))))))
