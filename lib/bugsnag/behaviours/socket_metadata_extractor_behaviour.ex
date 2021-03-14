defmodule Bugsnag.Behaviours.SocketMetadataExtractorBehaviour do
  @moduledoc """
  Behaviour defining the socket_metadata_extractor
  """

  @doc """
  Each key in the resulting map will become its own tab.
  Ensure that the map is json encodable.
  """
  @callback extract(%{assigns: map()}) :: map()
end
