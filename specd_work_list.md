# Work List

<!--
Single execution queue for all work — spec implementations, audit findings, and promoted review items.

HOW IT WORKS:

1. Pick an unblocked item (no `(blocked: ...)` annotation)
2. Implement it
3. Validate cross-file dependencies
4. Move the completed item from this file to specd_history.md
5. Check this file for items whose `(blocked: ...)` annotation references the
   work you just completed — remove the annotation to unblock them
6. Delete the spec header in this file if no more items are under it
7. LOOP_COMPLETE when this file has no unblocked items remaining

POPULATED BY: /specd:plan command (during spec phase), /specd:audit command, /specd:review-intake command, and humans.
-->

## standards v0.2

### Phase 2: Define domain types in owning modules

- Define `@type id :: String.t()` in `Deft.Message`. Update `Message.t` struct field, `Session.Entry.Message.message_id`, `OM.State.observed_message_ids`, and `Session.Entry.Observation.observed_message_ids` to use `Message.id()`
- Define `@type job_id :: String.t()` and `@type lead_id :: String.t()` in `Deft.Job`. Update `Job.Runner.LoopContext.job_id`, `Issue.job_id`, `Tool.Context.lead_id`, and `Store.name` tuple types to use them
- Define `@type id :: String.t()` in `Deft.Issue`. Update `Issue.t` fields `id` and `dependencies` to use `Issue.id()` and `[Issue.id()]` respectively. Update `Issue.Id.generate/1` spec
- Define `@type run_id :: String.t()` and `@type category :: String.t()` in `Deft.Eval`. Update specs in `Eval.ResultStore`, `Eval.Baselines`, `Eval.JudgeCalibration`, and `Eval.RegressionDetection` to use them (blocked: Define tool_name, tool_call_id, message id, job_id, lead_id, issue id types)

### Phase 3: Replace primitives in specs and structs

- Replace all `String.t()` session ID parameters in `Session.Store` specs (`append/3`, `load/2`, `resume/2`, `append_to_path/2`) with `Session.session_id()`
- Replace all `String.t()` session ID parameters in `OM.State` specs (`get_context/1`, `messages_added/2`, `force_observe/2`, `force_reflect/2`, `load_latest_snapshot/2`, `append_correction/2`) with `Session.session_id()`
- Replace all `String.t()` session ID parameters in `OM.Observer.run/4` and `OM.Reflector.run/4` with `Session.session_id()`
- Update `session_id` struct fields in `OM.State.t`, `Tool.Context.t`, `Session.Entry.SessionStart.t` to use `Session.session_id()`
- Replace all model/provider `String.t()` fields in `Config.t` (`model`, `provider`, `om_observer_model`, `om_observer_provider`, `om_reflector_model`, `om_reflector_provider`, `job_foreman_model`, `job_lead_model`, `job_runner_model`, `job_research_runner_model`) with `Provider.model_name()` and `Provider.provider_name()`
- Replace `config :: map()` in `Deft.Provider` callback with a typed `@type call_config` that has `model`, `temperature`, `max_tokens`, and optional `thinking`/`thinking_budget` fields. Update `Deft.Provider.Anthropic` to match
- Update `Deft.Store.name` type from `{:cache, String.t(), String.t()}` to `{:cache, Session.session_id(), Job.lead_id()}` and `{:sitelog, String.t()}` to `{:sitelog, Job.job_id()}` (blocked: Define job_id, lead_id types)

### Phase 4: Validate

- Run `mix dialyzer` with strict flags and fix any new violations introduced by the type changes. Ensure zero warnings, zero suppressed warnings.
