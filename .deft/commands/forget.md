Mark an observation as incorrect and remove it from memory.

## Usage

`/forget <text>` — Search for observations matching `<text>`, show them to the user, and ask for confirmation before marking as incorrect

## Instructions

When the user runs `/forget <text>`:

1. Use the forget tool with mode="search" and text="<text>" to find matching observations
2. Display the matching observations to the user
3. Ask the user to confirm: "Do you want to mark these observations as incorrect? (yes/no)"
4. If the user confirms:
   - Use the forget tool with mode="confirm" and text="<text>" to append the CORRECTION marker
   - Inform the user that the CORRECTION has been added
5. If the user declines or if no matches were found, inform them and stop

## Example

User: /forget we use PostgreSQL
Assistant: [searches and shows matches]
Assistant: "Do you want to mark these observations as incorrect?"
User: yes
Assistant: [confirms and uses forget tool with mode="confirm"]
