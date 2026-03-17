defmodule Deft.OM.Observer.Prompt do
  @moduledoc """
  Prompt engineering for the Observer LLM.

  Provides the system prompt for observation extraction and utilities for
  formatting input (message formatting, observation truncation).
  """

  alias Deft.Message
  alias Deft.OM.Tokens

  @doc """
  Returns the system prompt for the Observer.

  This prompt instructs the LLM to extract structured observations from
  conversation messages following the rules from the observational-memory spec.
  """
  @spec system() :: String.t()
  def system do
    """
    You are the Observer component of an AI coding agent's memory system.

    Your role is to extract structured observations from conversation messages and format them into sections. Observations are facts, decisions, preferences, and context that the agent needs to remember.

    ## What to Extract

    Extract the following types of information, using priority markers:

    **🔴 High Priority (explicit user facts and preferences):**
    - User assertions and facts (e.g., "we use PostgreSQL", "our API is REST")
    - User preferences — stated or demonstrated preferences about workflow, style, tools
    - Completed goals and critical context

    **🟡 Medium Priority (project details and learned information):**
    - **Files read and modified** — record file paths and their purpose/key contents (e.g., "Read `src/auth.ex` — contains JWT verification with `verify_token/1`")
    - **Errors encountered** — record error messages verbatim, what caused them, and whether they were resolved
    - **Commands run and outcomes** — what bash commands were executed and their result (pass/fail, key output)
    - **Architectural decisions with rationale** — not just "chose gen_statem" but "chose gen_statem because the agent loop has distinct states"
    - **Build/test state** — what passes, what fails, what was last run
    - **Dependencies and versions** — packages added/removed/upgraded (e.g., "Added jason ~> 1.4 to deps")
    - **Git state** — branch name, recent commits mentioned, merge conflicts
    - **Deferred work / TODOs** — things the user said to come back to ("we still need to handle the error case")
    - Conversation outcomes — decisions made, approaches chosen, problems solved
    - State changes — "User will start doing X (changing from Y)"

    **🟢 Low Priority (minor details):**
    - Minor details, uncertain observations

    ## Anti-Hallucination Rules

    **CRITICAL:** Only extract information that is directly stated or demonstrated in the messages. Do NOT infer unstated facts.

    - If an observation is uncertain, prefix it with "Likely:" (e.g., "Likely: user's project uses Phoenix based on deps")
    - If the user asks a hypothetical question, do NOT record it as a fact
    - If the user is exploring options ("what if we used X?"), do NOT record it as a decision
    - If the user is reading about something, do NOT record it as implemented
    - If the user is discussing alternatives, do NOT record a choice unless explicitly made
    - When in doubt, omit the observation rather than fabricate one

    ## Output Format

    Structure your observations into these sections in this exact order:

    ```
    ## Current State
    - (HH:MM) Active task: [brief description of current work]
    - (HH:MM) Last action: [most recent tool call or significant action]
    - (HH:MM) Blocking error: [current error or "none"]

    ## User Preferences
    - (HH:MM) 🔴 [user preference or workflow choice]

    ## Files & Architecture
    - (HH:MM) 🟡 Read [filepath] — [purpose/key contents]
    - (HH:MM) 🟡 Modified [filepath] — [what changed]
    - (HH:MM) 🟡 Architecture: [architectural decision with rationale]

    ## Decisions
    - (HH:MM) 🟡 [decision with rationale]

    ## Session History
    - (HH:MM) 🔴/🟡/🟢 [chronological event]
    ```

    **Section Rules:**
    - `## Current State` is regenerated each cycle — replace the entire section with fresh observations about the active task, last action, and blocking error
    - Other sections accumulate — append new observations to existing content
    - Use wall-clock timestamps (HH:MM format) from the message metadata
    - Convert relative time references ("last week", "next Thursday") to estimated calendar dates in parentheses at the end
    - Do NOT convert vague references like "recently"

    ## Temporal Anchoring

    Each observation carries a wall-clock timestamp from the source message in (HH:MM) format.

    When users mention relative dates:
    - Specific dates ("last Tuesday", "next week") → convert to estimated calendar dates and append in parentheses
    - Vague references ("recently", "earlier") → do NOT add estimated dates

    ## What NOT to Extract

    - Verbatim conversation flow ("User said X, Assistant replied Y") — extract the facts, not the dialogue
    - Internal reasoning or chain-of-thought
    - Redundant information already in existing observations

    ## Output Structure

    You must output your observations in this XML format:

    ```xml
    <observations>
    ## Current State
    - (HH:MM) Active task: ...
    - (HH:MM) Last action: ...
    - (HH:MM) Blocking error: none

    ## User Preferences
    ...

    ## Files & Architecture
    ...

    ## Decisions
    ...

    ## Session History
    ...
    </observations>

    <current-task>
    [One-line description of what the user is currently working on]
    </current-task>
    ```

    The `<current-task>` should be a single-line summary that will be used to provide conversation continuity.

    ## Example

    Given messages:
    ```
    **User (14:32):**
    I want to implement JWT authentication in src/auth.ex. We use argon2 for password hashing.

    **Assistant (14:32):**
    I'll help you implement JWT authentication. Let me first read the current auth module.

    **Assistant (14:32) [Tool Call: read]:**
    src/auth.ex

    **Assistant (14:32) [Tool Result: read]:**
    defmodule Auth do
      # Empty module
    end
    ```

    Output:
    ```xml
    <observations>
    ## Current State
    - (14:32) Active task: implementing JWT authentication in src/auth.ex
    - (14:32) Last action: read src/auth.ex
    - (14:32) Blocking error: none

    ## User Preferences
    - (14:32) 🔴 User uses argon2 for password hashing

    ## Files & Architecture
    - (14:32) 🟡 Read src/auth.ex — empty module, needs JWT implementation

    ## Decisions

    ## Session History
    - (14:32) 🔴 User wants to implement JWT authentication
    </observations>

    <current-task>
    Implementing JWT authentication in src/auth.ex
    </current-task>
    ```
    """
  end

  @doc """
  Formats messages for the Observer input.

  Converts a list of Deft.Message structs into a human-readable text format
  with timestamps, roles, and content.

  ## Format

  - Each message is formatted as `**Role (HH:MM):** content`
  - Tool calls are shown as `**Role (HH:MM) [Tool Call: name]:** args`
  - Tool results are shown as `**Role (HH:MM) [Tool Result: name]:** content`
  - Image attachments are noted as `[Image: filename.png]`

  ## Examples

      iex> messages = [
      ...>   %Deft.Message{
      ...>     id: "1",
      ...>     role: :user,
      ...>     content: [%Deft.Message.Text{text: "hello"}],
      ...>     timestamp: ~U[2026-03-17 14:32:00Z]
      ...>   }
      ...> ]
      iex> Deft.OM.Observer.Prompt.format_messages(messages)
      "**User (14:32):**\\nhello\\n\\n"
  """
  @spec format_messages([Message.t()]) :: String.t()
  def format_messages(messages) do
    messages
    |> Enum.map(&format_message/1)
    |> Enum.join("\n")
  end

  defp format_message(%Message{role: role, content: content, timestamp: timestamp}) do
    time = format_timestamp(timestamp)
    role_str = format_role(role)

    content
    |> Enum.map(fn block -> format_content_block(block, role_str, time) end)
    |> Enum.join("\n")
  end

  defp format_role(:user), do: "User"
  defp format_role(:assistant), do: "Assistant"
  defp format_role(:system), do: "System"

  defp format_timestamp(%DateTime{} = dt) do
    "#{String.pad_leading(Integer.to_string(dt.hour), 2, "0")}:#{String.pad_leading(Integer.to_string(dt.minute), 2, "0")}"
  end

  defp format_content_block(%Message.Text{text: text}, role, time) do
    "**#{role} (#{time}):**\n#{text}\n"
  end

  defp format_content_block(%Message.ToolUse{name: name, args: args}, role, time) do
    args_str = format_tool_args(args)
    "**#{role} (#{time}) [Tool Call: #{name}]:**\n#{args_str}\n"
  end

  defp format_content_block(%Message.ToolResult{name: name, content: content}, role, time) do
    # Truncate very long tool results for readability
    truncated_content = truncate_tool_result(content)
    "**#{role} (#{time}) [Tool Result: #{name}]:**\n#{truncated_content}\n"
  end

  defp format_content_block(%Message.Thinking{text: _text}, _role, _time) do
    # Skip thinking blocks in Observer input - they're internal reasoning
    ""
  end

  defp format_content_block(%Message.Image{}, role, time) do
    "**#{role} (#{time}):**\n[Image attachment]\n"
  end

  defp format_tool_args(args) when is_map(args) do
    args
    |> Enum.map(fn {key, value} -> "#{key}: #{inspect(value)}" end)
    |> Enum.join(", ")
  end

  defp truncate_tool_result(content) when byte_size(content) > 2000 do
    # Truncate to ~500 chars (roughly 125 tokens) for very long tool results
    String.slice(content, 0, 500) <> "\n[... truncated ...]"
  end

  defp truncate_tool_result(content), do: content

  @doc """
  Truncates observations to fit within the token budget for the Observer input.

  Takes existing observations and a token budget (default 8,000 tokens from spec),
  and returns a truncated version that fits within the budget.

  ## Strategy (from spec section 3.2)

  - Take the last 5,000 tokens (tail) — most recent observations
  - Scan the remainder for 🔴 high-priority lines and include them to fill the remaining 3,000 token budget
  - Add a marker `[N observations truncated]` at the top if any content was removed

  ## Examples

      iex> observations = \"\"\"
      ...> ## Current State
      ...> - (14:30) 🔴 Active task: implementing auth
      ...>
      ...> ## Session History
      ...> - (14:20) 🟡 Started working on auth
      ...> - (14:25) 🔴 User prefers simple solutions
      ...> \"\"\"
      iex> truncated = Deft.OM.Observer.Prompt.truncate_observations(observations, 8000)
      iex> String.contains?(truncated, "Active task")
      true
  """
  @spec truncate_observations(String.t(), integer()) :: String.t()
  def truncate_observations(observations, token_budget \\ 8_000)

  def truncate_observations("", _token_budget), do: ""

  def truncate_observations(observations, token_budget) do
    # Use default calibration factor of 4.0 for estimation
    current_tokens = Tokens.estimate(observations, 4.0)

    if current_tokens <= token_budget do
      # Fits within budget, no truncation needed
      observations
    else
      # Need to truncate - take tail + high-priority from head
      tail_budget = 5_000
      priority_budget = 3_000

      lines = String.split(observations, "\n")
      {tail_lines, _remaining_tokens} = take_tail_lines(lines, tail_budget)

      # Scan remaining lines for high-priority (🔴) markers
      head_lines = Enum.take(lines, length(lines) - length(tail_lines))
      priority_lines = extract_priority_lines(head_lines, priority_budget)

      # Calculate how many observations were truncated
      truncated_count = length(head_lines) - length(priority_lines)

      # Assemble result
      result =
        if truncated_count > 0 do
          marker = "[#{truncated_count} observations truncated]\n\n"
          marker <> Enum.join(priority_lines, "\n") <> "\n\n" <> Enum.join(tail_lines, "\n")
        else
          Enum.join(tail_lines, "\n")
        end

      result
    end
  end

  # Takes lines from the end until we reach the token budget
  defp take_tail_lines(lines, budget) do
    {taken, remaining_budget} =
      lines
      |> Enum.reverse()
      |> Enum.reduce_while({[], budget}, fn line, {acc, remaining} ->
        line_tokens = Tokens.estimate(line <> "\n", 4.0)

        if remaining >= line_tokens do
          {:cont, {[line | acc], remaining - line_tokens}}
        else
          {:halt, {acc, remaining}}
        end
      end)

    {taken, remaining_budget}
  end

  # Extracts lines with 🔴 markers from head, up to the budget
  defp extract_priority_lines(lines, budget) do
    {taken, _remaining_budget} =
      lines
      |> Enum.filter(&String.contains?(&1, "🔴"))
      |> Enum.reduce_while({[], budget}, fn line, {acc, remaining} ->
        line_tokens = Tokens.estimate(line <> "\n", 4.0)

        if remaining >= line_tokens do
          {:cont, {[line | acc], remaining - line_tokens}}
        else
          {:halt, {acc, remaining}}
        end
      end)

    Enum.reverse(taken)
  end
end
