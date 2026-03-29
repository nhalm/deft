defmodule Deft.Job do
  @moduledoc """
  Domain types and shared functionality for job orchestration.

  This module defines the core types used across the job orchestration
  subsystem (Foreman, Lead, Runner, RateLimiter, SiteLog).
  """

  @typedoc "Unique identifier for a job"
  @type job_id :: String.t()

  @typedoc "Unique identifier for a Lead within a job"
  @type lead_id :: String.t()
end
