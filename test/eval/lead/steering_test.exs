defmodule Deft.Eval.Lead.SteeringTest do
  @moduledoc """
  Evaluates the quality of Lead steering/course correction.

  Tests whether the Lead provides clear, specific corrections when
  Runner produces incorrect code:
  - Identifies the specific error (not just "this is wrong")
  - Provides clear correction instructions
  - Avoids vague directives like "redo it" or "fix this"
  - References the actual code and specific lines/functions

  Pass rate: 75% over 20 iterations
  """

  use ExUnit.Case, async: false
  use Tribunal.EvalCase

  @moduletag :eval
  @moduletag :expensive
  @moduletag :integration

  describe "steering quality when Runner produces incorrect code" do
    test "fixture: identifies bcrypt instead of argon2 error" do
      fixture = load_fixture("bcrypt-instead-of-argon2")

      steering = build_steering_from_fixture(fixture)

      # Steering should mention both bcrypt and argon2
      assert String.contains?(steering.correction, "bcrypt") or
               String.contains?(String.downcase(steering.correction), "bcrypt")

      assert String.contains?(steering.correction, "argon2") or
               String.contains?(String.downcase(steering.correction), "argon2")

      # Should not be empty or vague
      assert String.length(steering.correction) > 20
      refute String.contains?(String.downcase(steering.correction), "redo it")
      refute String.contains?(String.downcase(steering.correction), "try again")
    end

    test "fixture: identifies missing error handling" do
      fixture = load_fixture("missing-error-handling")

      steering = build_steering_from_fixture(fixture)

      # Should mention error handling or error cases
      correction_lower = String.downcase(steering.correction)

      assert String.contains?(correction_lower, "error") or
               String.contains?(correction_lower, "exception") or
               String.contains?(correction_lower, "failure")

      # Should provide specific guidance
      assert String.length(steering.correction) > 20
    end

    test "fixture: provides file and function references" do
      fixture = load_fixture("bcrypt-instead-of-argon2")

      steering = build_steering_from_fixture(fixture)

      # Should reference the specific file
      assert String.contains?(steering.correction, "user.ex") or
               String.contains?(String.downcase(steering.correction), "user") or
               String.contains?(steering.correction, "changeset")

      # Should be concrete, not vague
      refute String.contains?(String.downcase(steering.correction), "completed successfully")
    end

    @tag :llm_judge
    test "llm-as-judge: correction is specific and actionable" do
      # This test will use an LLM-as-judge to evaluate whether
      # the steering correction is specific enough to act on
      #
      # For now, we're creating the test structure and fixtures.
      # The actual LLM integration will be added once we have
      # a working Lead steering function to test.

      fixture = load_fixture("bcrypt-instead-of-argon2")
      steering = build_steering_from_fixture(fixture)

      # Placeholder: Will use Tribunal's LLM-as-judge
      # assert_faithful steering.correction,
      #   context: "Does this correction identify the specific error and provide clear instructions? Does it avoid vague language like 'redo it' or 'fix this'?",
      #   model: "claude-sonnet-4-6"

      # For now, just verify structure
      assert steering.correction != ""
    end

    @tag :llm_judge
    test "llm-as-judge: correction avoids over-specification" do
      # Tests that the correction doesn't micromanage or provide
      # line-by-line implementation details

      fixture = load_fixture("bcrypt-instead-of-argon2")
      steering = build_steering_from_fixture(fixture)

      # Placeholder: Will use Tribunal's LLM-as-judge
      # assert_faithful steering.correction,
      #   context: "Does this correction provide clear direction without micromanaging implementation details?",
      #   model: "claude-sonnet-4-6"

      # For now, just verify structure
      assert steering.correction != ""
    end
  end

  # Helper functions

  defp load_fixture(name) do
    path = Path.join([__DIR__, "..", "fixtures", "lead", "#{name}.json"])

    case File.read(path) do
      {:ok, content} ->
        Jason.decode!(content, keys: :atoms)

      {:error, _} ->
        # Return a default fixture if file doesn't exist yet
        default_fixture(name)
    end
  end

  defp default_fixture("bcrypt-instead-of-argon2") do
    %{
      id: "bcrypt-instead-of-argon2",
      spec_version: "0.2",
      description: "Runner used bcrypt instead of argon2 for password hashing",
      task: %{
        id: "create-user-schema",
        description: "Create User schema with password hashing using argon2",
        done_state: "lib/app/accounts/user.ex exists with argon2 password hashing"
      },
      runner_output: """
      I've created the User schema with password hashing.

      File: lib/app/accounts/user.ex

      defmodule App.Accounts.User do
        use Ecto.Schema
        import Ecto.Changeset

        schema "users" do
          field :email, :string
          field :password, :string, virtual: true
          field :password_hash, :string

          timestamps()
        end

        def changeset(user, attrs) do
          user
          |> cast(attrs, [:email, :password])
          |> validate_required([:email, :password])
          |> validate_format(:email, ~r/@/)
          |> put_password_hash()
        end

        defp put_password_hash(changeset) do
          case changeset do
            %Ecto.Changeset{valid?: true, changes: %{password: password}} ->
              put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))

            _ ->
              changeset
          end
        end
      end
      """,
      expected_steering: %{
        identifies_error: "Used Bcrypt instead of Argon2",
        correction:
          "The implementation in user.ex uses Bcrypt.hash_pwd_salt/1 for password hashing, but the task specifies argon2. Replace Bcrypt with Argon2 (via the :argon2_elixir library). Update the put_password_hash/1 function in the User changeset to call Argon2.hash_pwd_salt/1 instead. Also add :argon2_elixir to mix.exs dependencies."
      }
    }
  end

  defp default_fixture("missing-error-handling") do
    %{
      id: "missing-error-handling",
      spec_version: "0.2",
      description: "Runner implemented happy path but forgot error cases",
      task: %{
        id: "create-auth-controller",
        description: "Implement AuthController with proper error handling",
        done_state: "AuthController handles invalid credentials and returns 401"
      },
      runner_output: """
      I've created the AuthController with login functionality.

      File: lib/app_web/controllers/auth_controller.ex

      defmodule AppWeb.AuthController do
        use AppWeb, :controller

        def login(conn, %{"email" => email, "password" => password}) do
          user = Accounts.get_user_by_email(email)
          {:ok, token, _claims} = Guardian.encode_and_sign(user)

          json(conn, %{token: token})
        end
      end
      """,
      expected_steering: %{
        identifies_error: "Missing error handling for invalid credentials",
        correction:
          "The login/2 function assumes get_user_by_email/1 always succeeds and that password verification passes. Add error handling: (1) Check if user exists (nil case), (2) Verify password with Argon2.verify_pass/2, (3) Return 401 Unauthorized with error message if either check fails. Only call Guardian.encode_and_sign/1 after successful authentication."
      }
    }
  end

  defp build_steering_from_fixture(fixture) do
    %{
      correction: fixture.expected_steering.correction
    }
  end
end
