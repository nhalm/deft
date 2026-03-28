[
  # Credo custom check - Credo is a dev/test dependency, callbacks not available at runtime
  ~r/lib\/deft\/checks\/function_body_length.ex.*(callback_info_missing|unknown_function)/,
  # Mix tasks - Mix is available but some functions not detected properly
  ~r/lib\/mix\/tasks\/.*(callback_info_missing|unknown_function)/,
  # Lead unused functions - designed for future use but not currently reachable
  ~r/lib\/deft\/job\/lead.ex.*unused_fun/
]
