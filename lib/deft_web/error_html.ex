defmodule DeftWeb.ErrorHTML do
  @moduledoc """
  Minimal error handler for Phoenix endpoint.
  Renders error pages for 404, 500, etc.
  """

  import Phoenix.HTML

  # Render error pages as plain HTML strings
  def render("404.html", _assigns) do
    raw("""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Not Found</title>
      </head>
      <body>
        <h1>404 - Page Not Found</h1>
        <p>The page you are looking for does not exist.</p>
      </body>
    </html>
    """)
  end

  def render("500.html", _assigns) do
    raw("""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Server Error</title>
      </head>
      <body>
        <h1>500 - Server Error</h1>
        <p>Something went wrong on our end.</p>
      </body>
    </html>
    """)
  end

  # Fallback for any other error template
  def render(template, _assigns) do
    raw("""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Error</title>
      </head>
      <body>
        <h1>Error</h1>
        <p>An error occurred: #{template}</p>
      </body>
    </html>
    """)
  end
end
