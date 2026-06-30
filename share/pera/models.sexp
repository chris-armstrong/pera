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
         (cache_write_per_mtok 3.75))))))))))
