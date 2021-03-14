defmodule Bugsnag.Logger do
  require Bugsnag
  require Logger

  @behaviour :gen_event

  def init([]), do: {:ok, []}

  def handle_call({:configure, new_keys}, _state) do
    {:ok, :ok, new_keys}
  end

  def handle_event({_level, gl, _event}, state)
      when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({:error_report, _gl, {_pid, _type, [message | _]}}, state)
      when is_list(message) do
    case message[:initial_call] do
      # do nothing in case of live_view
      {Phoenix.LiveView.Channel, :init, _} ->
        nil

      _ ->
        handle_error(message)
    end

    {:ok, state}
  end

  # Handle event for LiveView
  def handle_event(
        {:error, _gl,
         {pid, _msg,
          [
            pid,
            last_event,
            %{socket: %{assigns: %{}} = socket},
            {exception, stacktrace}
          ]}},
        state
      )
      when is_list(stacktrace) do
    # Handle liveview
    try do
      # We only want to send the last event for Phoenix.Socket.Message
      last_event =
        case last_event do
          %{payload: payload} -> payload
          _ -> nil
        end

      base_metadata = %{last_event: last_event}
      options = %{stacktrace: stacktrace}

      options =
        case extract_socket_metadata(socket) do
          %{metadata: metadata} ->
            Map.put(options, :metadata, Map.merge(base_metadata, metadata))

          other when is_map(other) ->
            options |> Map.put(:metadata, base_metadata) |> Map.merge(other)
        end
        |> Keyword.new()

      Bugsnag.report(exception, options)
    rescue
      ex -> report_failure(ex)
    end

    {:ok, state}
  end

  def handle_event({_level, _gl, _event}, state) do
    {:ok, state}
  end

  defp handle_error(message) do
    try do
      error_info = message[:error_info]

      case error_info do
        # Else do the following
        {_kind, {exception, stacktrace}, _stack} when is_list(stacktrace) ->
          Bugsnag.report(exception, stacktrace: stacktrace)

        {_kind, exception, stacktrace} ->
          Bugsnag.report(exception, stacktrace: stacktrace)
      end
    rescue
      ex -> report_failure(ex)
    end
  end

  defp report_failure(ex) do
    error_message = Exception.format(:error, ex)
    Logger.warn("Unable to notify Bugsnag. #{error_message}")
  end

  defp extract_socket_metadata(socket) do
    extractor = Application.get_env(:bugsnag, :socket_metadata_extractor)

    if extractor do
      {module, function} = extractor
      %{metadata: apply(module, function, [socket])}
    else
      extract_user_info(socket)
    end
  end

  defp extract_user_info(socket) do
    %{
      user: socket.assigns[:current_user] |> user_info()
    }
  end

  defp user_info(%{id: id, name: name, email: email}) do
    %{id: id, email: email, name: name}
  end

  defp user_info(_), do: nil
end
