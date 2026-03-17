defmodule Deft.OM.Reflector.Prompt do
  @moduledoc """
  Prompt engineering for the Reflector LLM.

  Provides the system prompt for observation compression with configurable
  target size and compression level.
  """

  @doc """
  Returns the system prompt for the Reflector.

  Takes a map with:
  - `:target_size` — target token count for compressed output (default 20,000)
  - `:compression_level` — compression aggressiveness level 0-3 (default 0)

  This prompt instructs the LLM to compress observations while preserving
  structure, priority items, and CORRECTION markers.

  ## Examples

      iex> prompt = Deft.OM.Reflector.Prompt.system(target_size: 20_000, compression_level: 0)
      iex> String.contains?(prompt, "target size: 20,000 tokens")
      true

      iex> prompt = Deft.OM.Reflector.Prompt.system(target_size: 15_000, compression_level: 2)
      iex> String.contains?(prompt, "Level 2")
      true
  """
  @spec system(keyword()) :: String.t()
  def system(opts \\ []) do
    target_size = Keyword.get(opts, :target_size, 20_000)
    compression_level = Keyword.get(opts, :compression_level, 0)

    """
    You are the Reflector component of an AI coding agent's memory system.

    Your role is to compress observations when they grow too large, while preserving the most important information. You must maintain the section structure and ordering, and ensure all CORRECTION markers survive compression.

    ## Compression Task

    **Target size: #{format_number(target_size)} tokens**

    Your goal is to compress the observations to fit within the target size while preserving:
    - All 🔴 high-priority observations
    - Section structure and ordering
    - CORRECTION markers (CRITICAL — these must never be lost)
    - Recent observations (prioritize recency)
    - Key context needed for the agent to function effectively

    #{compression_level_guidance(compression_level)}

    ## Section Structure (MUST PRESERVE THIS ORDER)

    Your output MUST contain these sections in this exact order:

    1. **## Current State** (~500 tokens)
       - Active task, last action, blocking error
       - Always keep this section — it's the most important for agent orientation

    2. **## User Preferences** (~1,000 tokens)
       - All user preferences and workflow choices
       - These are almost always 🔴 high-priority — preserve aggressively

    3. **## Files & Architecture** (~8,000 tokens)
       - File read/modify history and architectural decisions
       - Keep recent file operations and major architectural choices
       - Merge related file operations when compressing

    4. **## Decisions** (~3,000 tokens)
       - Key decisions with their rationale
       - Preserve decisions that inform future work

    5. **## Session History** (remaining budget)
       - Chronological log of the session
       - This section bears the brunt of compression
       - Merge related events, drop 🟢 items first, then old 🟡 items

    The token budgets above are guidance — allocate as needed, but preserve the ordering.

    ## CORRECTION Markers (CRITICAL)

    Lines containing "CORRECTION:" are user corrections of false observations. These MUST survive compression at all costs. Do NOT drop, merge, or modify any line containing "CORRECTION:".

    If you must compress a section containing CORRECTION markers, drop other lines around them but keep the CORRECTION lines verbatim.

    ## Compression Strategies

    - **Merge related observations:** Combine multiple observations about the same file, error, or decision
    - **Drop low-priority old items:** Remove 🟢 items older than 1 day, then old 🟡 items as needed
    - **Preserve temporal flow:** Keep timestamps to maintain chronological context
    - **Summarize command sequences:** "Ran tests 3 times, all passed after fixing X" instead of listing each run
    - **Keep error resolutions:** If an error was encountered and fixed, keep the resolution, optionally drop the initial error
    - **Preserve user facts:** User assertions, preferences, and project details are usually 🔴 — keep them

    ## What NOT to Do

    - Do NOT reorder sections or create new sections
    - Do NOT drop CORRECTION markers
    - Do NOT fabricate new observations
    - Do NOT merge observations in a way that loses meaning
    - Do NOT drop all observations from a section (except if truly empty)

    ## Output Format

    Return the compressed observations in the same markdown format as the input:

    ```
    ## Current State
    - (HH:MM) Active task: ...
    - (HH:MM) Last action: ...
    - (HH:MM) Blocking error: ...

    ## User Preferences
    - (HH:MM) 🔴 ...

    ## Files & Architecture
    - (HH:MM) 🟡 ...

    ## Decisions
    - (HH:MM) 🟡 ...

    ## Session History
    - (HH:MM) 🔴/🟡/🟢 ...
    ```

    Maintain the emoji priority markers (🔴🟡🟢) and timestamps (HH:MM) in your output.
    """
  end

  defp format_number(num) when num >= 1000 do
    thousands = div(num, 1000)
    remainder = rem(num, 1000)

    if remainder == 0 do
      "#{thousands},000"
    else
      "#{thousands},#{String.pad_leading(Integer.to_string(remainder), 3, "0")}"
    end
  end

  defp format_number(num), do: Integer.to_string(num)

  defp compression_level_guidance(0) do
    """
    **Compression Level 0: Gentle**

    - Let your judgment guide what to drop
    - No specific compression rules — focus on the target size
    - Prefer recent observations over old ones
    - Keep all 🔴 items, most 🟡 items, selectively drop 🟢 items
    """
  end

  defp compression_level_guidance(1) do
    """
    **Compression Level 1: Moderate**

    You need to compress more aggressively:
    - Merge related observations (e.g., multiple reads of the same file)
    - Drop all 🟢 items older than 1 day
    - Summarize command sequences and test runs
    - Keep 🔴 items and recent 🟡 items
    """
  end

  defp compression_level_guidance(2) do
    """
    **Compression Level 2: Aggressive**

    The observations are still too large — compress heavily:
    - Drop ALL 🟢 items regardless of age
    - Aggressively merge related 🟡 observations
    - Summarize groups of 🟡 items (e.g., "Modified 5 files in auth module")
    - Keep all 🔴 items and only the most critical recent 🟡 items
    - Significantly reduce Session History (keep only last day or key events)
    """
  end

  defp compression_level_guidance(3) do
    """
    **Compression Level 3: Maximum**

    This is the final attempt — compress to the absolute minimum:
    - Keep ONLY 🔴 items (except where impossible)
    - Keep ONLY the most recent day of activity
    - Session History should be heavily compressed to key outcomes only
    - If the target size is still not met, do your best and return what you have
    - NEVER drop CORRECTION markers
    """
  end
end
