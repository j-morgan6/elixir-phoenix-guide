defmodule GoodLogger do
  require Logger

  def expired(user), do: Logger.info("token expired for user #{user.id}", user_id: user.id)
end
