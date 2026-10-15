defmodule BadLoggerWarning do
  require Logger

  def reset(user, token), do: Logger.warning("password reset for #{user.id} with token #{token}")
end
