# {PROJECT_NAME}

## Build & Test

<!-- Customize: add your project's build and test commands here -->
- Run the project's test suite to catch errors
- Validate with the full test suite, not just unit tests. If integration tests fail, that's a real failure — do not dismiss them.

## Conventions

- Follow patterns in existing code for naming, structure, and style
- Match the language and framework conventions of the project
<!-- Customize: add language-specific conventions here -->

### Interfaces and Dependencies

- **Use interfaces for external dependencies.** Database access, HTTP clients, external services — anything that crosses a boundary.
- **Mock at boundaries, not internals.** Mock the interface, not implementation details.
- **Dependency injection over globals.** Pass dependencies explicitly rather than importing singletons.
