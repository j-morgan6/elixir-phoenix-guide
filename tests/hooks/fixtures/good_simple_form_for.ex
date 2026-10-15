defmodule GoodSimpleFormFor do
  def simple_form_for(changeset), do: changeset
  def build(cs), do: simple_form_for(cs)
end
