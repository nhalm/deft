# Deft

An AI coding agent with observational memory.

## Architecture

Every session starts the same process tree. The Foreman is the agent the user talks to. For simple tasks, the Foreman handles everything directly (LeadSupervisor stays empty). For complex tasks, it spawns Leads.

```mermaid
graph TD
    subgraph "Deft.Supervisor (one_for_one)"
        REG_DUP["Deft.Registry<br/><small>duplicate — pub/sub</small>"]
        REG_UNI["Deft.ProcessRegistry<br/><small>unique — named lookup</small>"]
        PROV["Deft.Provider.Registry"]
        SKILLS["Deft.Skills.Registry"]
        PUBSUB["Phoenix.PubSub"]
        ENDPOINT["DeftWeb.Endpoint"]
        ISSUES["Deft.Issues<br/><small>optional</small>"]

        subgraph SESSION_SUP["Deft.Session.Supervisor (DynamicSupervisor)"]
            subgraph WORKER["Session.Worker (rest_for_one)"]
                SITELOG["Deft.Store<br/><small>site log — ETS+DETS</small>"]
                RATE["Deft.RateLimiter"]
                F_TR["Deft.Agent.ToolRunner<br/><small>Foreman tools</small>"]
                FOREMAN["Deft.Foreman<br/><small>Deft.Agent — LLM loop, OM<br/>writes session_id.jsonl</small>"]
                F_RUNNERS["Task.Supervisor<br/><small>research / verification Runners</small>"]
                subgraph OM_SUP["Deft.OM.Supervisor (rest_for_one)"]
                    OM_TASKS["Task.Supervisor"]
                    OM_STATE["Deft.OM.State"]
                end
                COORD["Deft.Foreman.Coordinator<br/><small>gen_statem — orchestration<br/>DAG, monitors, coalescing</small>"]

                subgraph LEAD_SUP["Deft.LeadSupervisor (DynamicSupervisor)"]
                    subgraph LEAD_WRAP["Lead.Supervisor (one_for_one)<br/><small>per lead, on demand</small>"]
                        LA_TR["Deft.Agent.ToolRunner<br/><small>Lead tools</small>"]
                        LA["Deft.Lead<br/><small>Deft.Agent — LLM loop, OM</small>"]
                        R_SUP["Task.Supervisor<br/><small>Runner tasks</small>"]
                        LEAD_COORD["Deft.Lead.Coordinator<br/><small>gen_statem</small>"]
                        RUNNERS["Runners<br/><small>async_nolink tasks<br/>inline loops, no OM</small>"]
                    end
                end
            end
        end
    end

    COORD -- "prompts" --> FOREMAN
    FOREMAN -- "tool actions" --> COORD
    LEAD_COORD -- "messages" --> COORD
    COORD -- "steering" --> LEAD_COORD
    LEAD_COORD -- "prompts" --> LA
    LA -- "tool actions" --> LEAD_COORD
    LEAD_COORD -- "spawns" --> RUNNERS
```
