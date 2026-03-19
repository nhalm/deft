Send a course-correction to the Foreman during job execution, or correct an observation in a regular session.

## Usage

- `/correct <message>` — Send a course-correction during job execution (auto-promoted to site log)
- `/correct <old> → <new>` — Correct an observation by replacing incorrect text

## Instructions

### Job Correction (when Foreman is active)

When the user runs `/correct <message>` without `→` during a job:

1. Add the prefix `__JOB_CORRECTION__: ` to the message
2. The Foreman will detect this prefix, auto-promote the correction to the site log, and make it available to all Leads

### Observation Correction (regular sessions)

When the user runs `/correct <old> → <new>`:

1. Parse the command to extract `<old>` and `<new>` from the `→` separator
2. Use the correct tool with mode="search", old="<old>", and new="<new>" to find matching observations
3. Display the matching observations to the user
4. Ask the user to confirm: "Do you want to replace these observations? (yes/no)"
5. If the user confirms:
   - Use the correct tool with mode="confirm", old="<old>", and new="<new>" to append the CORRECTION marker
   - Inform the user that the CORRECTION has been added
6. If the user declines or if no matches were found, inform them and stop

## Examples

**Job correction:**
```
User: /correct Focus on the backend API first, skip the frontend for now
Assistant: __JOB_CORRECTION__: Focus on the backend API first, skip the frontend for now
[Foreman auto-promotes to site log]
```

**Observation correction:**
```
User: /correct we use PostgreSQL → we use SQLite
Assistant: [searches and shows matches]
Assistant: "Do you want to replace these observations?"
User: yes
Assistant: [confirms and uses correct tool with mode="confirm"]
```
