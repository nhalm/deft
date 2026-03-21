# Phoenix Minimal

Minimal Phoenix application for eval test fixtures.

## Structure

- `mix.exs` - Project dependencies
- `lib/phoenix_minimal/` - Core application
  - `application.ex` - Application supervisor
  - `repo.ex` - Ecto repository
  - `accounts/user.ex` - User schema
- `lib/phoenix_minimal_web/` - Web layer
  - `endpoint.ex` - Phoenix endpoint
  - `router.ex` - Route definitions
  - `controllers/user_controller.ex` - User API controller

## Purpose

This is a synthetic codebase snapshot used for Foreman and Lead eval tests. It provides:
- A realistic Phoenix project structure
- Ecto schemas for database operations
- RESTful API endpoints
- Enough complexity to test decomposition and planning
