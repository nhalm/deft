Correct an observation by replacing incorrect text with correct text.

## Usage

`/correct <old> → <new>` — Search for observations matching `<old>`, show them to the user, and ask for confirmation before appending a CORRECTION marker to replace the text

## Instructions

When the user runs `/correct <old> → <new>`:

1. Parse the command to extract `<old>` and `<new>` from the `→` separator
2. Use the correct tool with mode="search", old="<old>", and new="<new>" to find matching observations
3. Display the matching observations to the user
4. Ask the user to confirm: "Do you want to replace these observations? (yes/no)"
5. If the user confirms:
   - Use the correct tool with mode="confirm", old="<old>", and new="<new>" to append the CORRECTION marker
   - Inform the user that the CORRECTION has been added
6. If the user declines or if no matches were found, inform them and stop

## Example

User: /correct we use PostgreSQL → we use SQLite
Assistant: [searches and shows matches]
Assistant: "Do you want to replace these observations?"
User: yes
Assistant: [confirms and uses correct tool with mode="confirm"]
