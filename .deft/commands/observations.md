Display observational memory content.

## Usage

- `/observations` — Show summary (Current State + User Preferences + today's entries)
- `/observations --full` — Show all observations
- `/observations --search <term>` — Search observations for specific term

## Instructions

Parse the user's command to determine the mode:

1. If the command is just `/observations`, use the observations tool with mode: "summary"
2. If the command includes `--full`, use the observations tool with mode: "full"
3. If the command includes `--search <term>`, use the observations tool with mode: "search" and search_term: "<term>"

After retrieving the observations, display them directly to the user with no additional commentary.
