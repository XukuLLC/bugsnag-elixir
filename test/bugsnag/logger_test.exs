defmodule Bugsnag.LoggerTest do
  use ExUnit.Case

  alias Bugsnag.HTTPMock
  alias Bugsnag.HTTPClient.Request
  alias Bugsnag.HTTPClient.Response
  import ExUnit.CaptureLog
  import Mox

  @receive_timeout 1_000

  setup :set_mox_global
  setup :verify_on_exit!

  setup_all do
    Application.put_env(:bugsnag, :release_stage, "test")
    Application.put_env(:bugsnag, :notify_release_stages, ["test"])
    Application.put_env(:bugsnag, :http_client, HTTPMock)

    on_exit(fn ->
      Application.delete_env(:bugsnag, :release_stage)
      Application.delete_env(:bugsnag, :notify_release_stages)
      Application.delete_env(:bugsnag, :http_client)
    end)
  end

  test "logging a crash" do
    parent = self()
    ref = make_ref()

    Mox.expect(HTTPMock, :post, fn %Request{body: body} ->
      if exception?(body, "Elixir.RuntimeError", "Oh noes") do
        send(parent, {:post, ref})
      end

      {:ok, Response.new(200, [], "body")}
    end)

    :proc_lib.spawn(fn ->
      raise RuntimeError, "Oh noes"
    end)

    assert_receive {:post, ^ref}, @receive_timeout
    verify!()
  end

  test "crashes do not cause recursive logging" do
    parent = self()
    ref = make_ref()

    Mox.expect(HTTPMock, :post, fn %Request{body: body} ->
      if exception?(body, "Elixir.RuntimeError", "Oops") do
        send(parent, {:post, ref})
      end

      {:ok, Response.new(500, [], "body")}
    end)

    error_report = [[error_info: {:error, %RuntimeError{message: "Oops"}, []}], []]
    :error_logger.error_report(error_report)

    assert_receive {:post, ^ref}, @receive_timeout
    verify!()
  end

  test "log levels lower than :error_report are ignored" do
    parent = self()
    ref = make_ref()

    Mox.expect(HTTPMock, :post, 0, fn _request ->
      send(parent, {:post, ref})
      {:error, :just_no}
    end)

    message_types = [:info_msg, :info_report, :warning_msg, :error_msg]

    Enum.each(message_types, fn type ->
      apply(:error_logger, type, ["Ignore me"])
    end)

    refute_receive {:post, ^ref}, @receive_timeout
    verify!()
  end

  test "logging exceptions from special processes" do
    parent = self()
    ref = make_ref()

    Mox.expect(HTTPMock, :post, fn %Request{body: body} ->
      if exception?(body, "Elixir.ArgumentError", "argument error") do
        send(parent, {:post, ref})
      end

      {:ok, Response.new(200, [], "body")}
    end)

    :proc_lib.spawn(fn ->
      Float.parse("12.345e308")
    end)

    assert_receive {:post, ^ref}, @receive_timeout
    verify!()
  end

  test "logging exceptions from Tasks" do
    parent = self()
    ref = make_ref()

    Mox.expect(HTTPMock, :post, fn %Request{body: body} ->
      if exception?(body, "Elixir.ArgumentError", "argument error") do
        send(parent, {:post, ref})
      end

      {:ok, Response.new(200, [], "body")}
    end)

    Task.start(fn ->
      Float.parse("12.345e308")
    end)

    assert_receive {:post, ^ref}, @receive_timeout
    verify!()
  end

  test "logging exceptions from GenServers" do
    parent = self()
    ref = make_ref()

    Mox.expect(HTTPMock, :post, fn %Request{body: body} ->
      if exception?(body, "Elixir.RuntimeError", "but no handle_cast") do
        send(parent, {:post, ref})
      end

      {:ok, Response.new(200, [], "body")}
    end)

    {:ok, pid} = ErrorServer.start()
    GenServer.cast(pid, :fail)

    assert_receive {:post, ^ref}, @receive_timeout
    verify!()
  end

  test "logging exceptions from LiveView" do
    # Ensure we ignore the liveview event in :error_report handler.
    error_report_event =
      {:error_report, self(),
       {self(), :error, [initial_call: {Phoenix.LiveView.Channel, :init, []}]}}

    log_msg =
      capture_log(fn ->
        Bugsnag.Logger.handle_event(error_report_event, :state)
      end)

    assert log_msg == ""

    # Ensure we log liveview specific error events in :error handler.
    exception = %RuntimeError{message: "Jerry"}
    stacktrace = []

    error_event =
      {:error, :anything,
       {self(), :anything,
        [
          self(),
          :last_event,
          %{
            socket: %{
              assigns: %{current_user: %{id: 1, name: "Tom", email: "tom@tomandjerry.com"}}
            }
          },
          {exception, stacktrace}
        ]}}

    parent = self()
    ref = make_ref()

    Mox.expect(HTTPMock, :post, fn %Request{body: body} ->
      if exception?(body, "Elixir.RuntimeError", "Jerry") do
        send(parent, {:post, ref})
      end

      {:ok, Response.new(200, [], "body")}
    end)

    Bugsnag.Logger.handle_event(error_event, :state)

    assert_receive {:post, ^ref}, @receive_timeout
    verify!()
  end

  test "warns if error report format is invalid" do
    event = {:error_report, :gl, {:pid, :type, [[error_info: :invalid]]}}

    log_msg =
      capture_log(fn ->
        Bugsnag.Logger.handle_event(event, :state)
      end)

    assert log_msg =~ "Unable to notify Bugsnag. ** (CaseClauseError)"
  end

  defp exception?(body, error_class, message) do
    %{
      "events" => [
        %{
          "exceptions" => [
            %{
              "errorClass" => exception_error_class,
              "message" => exception_message
            }
          ]
        }
      ]
    } = Jason.decode!(body)

    exception_error_class =~ error_class and exception_message =~ message
  end
end
