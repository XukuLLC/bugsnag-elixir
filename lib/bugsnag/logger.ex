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

      Bugsnag.report(exception,
        stacktrace: stacktrace,
        last_event: last_event,
        metadata: socket |> extract_socket_metadata() |> Map.put(:last_event, last_event)
      )
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
      case apply(extractor, :extract, [socket]) do
        map when is_map(map) -> map
        _ -> %{notice: "Invalid socket_metadata_extractor"}
      end
    else
      %{}
    end
  end
end
