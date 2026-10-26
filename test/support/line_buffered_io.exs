# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Vutuv.Test.LineBufferedIO do
  @moduledoc false

  # Keep partial writes from independent formatters on their own output lines.
  # This adapter does not inspect test events or interpret output contents.
  def install do
    leader = Process.group_leader()
    proxy = spawn_link(fn -> loop(leader, %{}) end)
    Process.group_leader(self(), proxy)

    System.at_exit(fn _ ->
      # Registered before ExUnit starts: its autorun callback runs first.
      # Mix also finishes its complete suite before exit callbacks run.
      case flush(proxy) do
        :ok -> :ok
        error -> raise "Could not flush test output: #{inspect(error)}"
      end
    end)

    proxy
  end

  def start(leader), do: spawn_link(fn -> loop(leader, %{}) end)

  def flush(proxy) do
    ref = make_ref()
    monitor = Process.monitor(proxy)
    send(proxy, {:flush, self(), ref})

    receive do
      {^ref, reply} ->
        Process.demonitor(monitor, [:flush])
        reply

      {:DOWN, ^monitor, :process, ^proxy, reason} ->
        exit({:line_buffered_io_down, reason})
    end
  end

  defp loop(leader, buffers) do
    receive do
      {:io_request, from, reply_as, request} ->
        {reply, buffers} = request(request, from, leader, buffers)
        send(from, {:io_reply, reply_as, reply})
        loop(leader, buffers)

      {:flush, from, ref} ->
        reply =
          Enum.reduce_while(buffers, :ok, fn {_writer, bytes}, :ok ->
            case :io.request(leader, {:put_chars, :unicode, bytes}) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)

        send(from, {ref, reply})
        loop(leader, %{})
    end
  end

  defp request({:requests, requests}, from, leader, buffers) do
    Enum.reduce_while(requests, {:ok, buffers}, fn req, {_reply, buffers} ->
      case request(req, from, leader, buffers) do
        {{:error, _}, _} = result -> {:halt, result}
        result -> {:cont, result}
      end
    end)
  end

  defp request({:put_chars, chars}, from, leader, buffers),
    do: request({:put_chars, :latin1, chars}, from, leader, buffers)

  defp request({:put_chars, module, function, args}, from, leader, buffers),
    do: request({:put_chars, :latin1, module, function, args}, from, leader, buffers)

  defp request({:put_chars, encoding, module, function, args}, from, leader, buffers) do
    request({:put_chars, encoding, apply(module, function, args)}, from, leader, buffers)
  rescue
    _ -> {{:error, :put_chars}, buffers}
  end

  defp request({:put_chars, encoding, chars}, from, leader, buffers) do
    case :unicode.characters_to_binary(chars, encoding) do
      bytes when is_binary(bytes) ->
        bytes = Map.get(buffers, from, "") <> bytes

        case :binary.matches(bytes, "\n") do
          [] ->
            {:ok, Map.put(buffers, from, bytes)}

          matches ->
            {last, 1} = List.last(matches)
            <<complete::binary-size(last + 1), pending::binary>> = bytes
            reply = :io.request(leader, {:put_chars, :unicode, complete})

            buffers =
              if pending == "",
                do: Map.delete(buffers, from),
                else: Map.put(buffers, from, pending)

            {reply, buffers}
        end

      _ ->
        {{:error, :put_chars}, buffers}
    end
  rescue
    _ -> {{:error, :put_chars}, buffers}
  end

  defp request(request, _from, leader, buffers),
    do: {:io.request(leader, request), buffers}
end
