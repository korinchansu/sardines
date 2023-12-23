defmodule Sardines.Stream do
  @moduledoc false

  import Sardines.Frame.Flag, only: :macros

  alias Sardines.Headers
  alias Sardines.Frame
  alias Sardines.Stream.FSM


  defstruct id: nil, state: :idle, window_size: nil, content_length: nil, buffered_content_length: 0

  def log(msg) do
    :error_logger.format('~p', [msg])
  end


  # Header Continuation validation

  def event(frame_type, _, _, _, %{cont_stream_id: cont_stream_id} = conn_state) 
  when not is_nil(cont_stream_id) and not frame_type == :continutation do
    %{conn_state|error: {:connection_error, :protocol_error}}
  end

  def event(_, %{id: id}, _, _, %{cont_stream_id: cont_stream_id} = conn_state) 
  when not is_nil(cont_stream_id) and cont_stream_id != id do
    %{conn_state|error: {:connection_error, :protocol_error}}
  end


  # New Stream

  def event(_, {:new_stream, _}, _, _, %{settings: %{max_concurrent_streams: max_concurrent_streams},
                                         concurrent_count: concurrent_count} = conn_state) 
  when concurrent_count == max_concurrent_streams do
    %{conn_state|error: {:connection_error, :protocol_error}}
  end

  def event(_, {:new_stream, 0}, _, _, conn_state) do 
    %{conn_state|error: {:connection_error, :protocol_error}}
  end


  # Headers

  def event(:headers, {:new_stream, stream_id}, _, _, %{last_stream_id: last_stream_id} = conn_state)
  when stream_id < last_stream_id do
    %{conn_state|error: {:connection_error, :protocol_error}}
  end

  def event(:headers, {:new_stream, stream_id}, flags, payload, conn_state) do
    stream = %__MODULE__{id: stream_id, window_size: conn_state.settings.initial_window_size}
    conn_state = %{conn_state|last_stream_id: stream_id}
    event(:headers, stream, flags, payload, conn_state)
  end

  def event(_, {:new_stream, _}, _, _, conn_state) do
    %{conn_state|error: {:connection_error, :protocol_error}}
  end

  def event(:headers, stream, flags, {priority, data}, conn_state) do
    conn_state = event(:priority, stream, flags, priority, conn_state)
    event(:headers, stream, flags, data, conn_state)
  end

  def event(:headers, stream, flags, data, %{decode_context: decode_context, 
                                             cont_stream_id: cont_stream_id} = conn_state) do
    new_state = FSM.next_state(:headers, stream.state, flags)
    conn_state = handle_concurrency_count(stream.state, new_state, conn_state)
    case new_state do
      {:cont, then_state} when is_nil(cont_stream_id) ->
        streams = Map.put(conn_state.streams, stream.id, %{stream|state: new_state})
        %{conn_state|streams: streams, cont_stream_id: stream.id, cont_buffer: data}
      {:cont, then_state} -> 
        %{conn_state|error: {:connection_error, :protocol_error}}
      {:error, error} ->
        %{conn_state|error: {:connection_error, error}}
      _ ->
        log(stream.id)
        case Headers.decode(data, decode_context) do
          {:error, error} -> 
            %{conn_state|error: {:connection_error, error}}
          {:ok, headers, decode_context} -> 
 
    log(stream.id)
            content_length = Keyword.get(headers, :'content-length') |> Sardines.Headers.parse_content_length
            stream = %{stream|state: new_state, content_length: content_length}
            streams = Map.put(conn_state.streams, stream.id, stream)
            %{conn_state|streams: streams, decode_context: decode_context}
        end
    end
  end

  def event(:continuation, stream, flags, data, %{decode_context: decode_context, 
                                                  cont_stream_id: cont_stream_id} = conn_state) do

    new_state = FSM.next_state(:continuation, stream.state, flags)
    conn_state = handle_concurrency_count(stream.state, new_state, conn_state)
    id = stream.id

    case new_state do
      {:cont, then_state} when id == cont_stream_id -> 
        %{conn_state|cont_stream_id: stream.id, cont_buffer: conn_state.cont_buffer <> data}
      {:cont, then_state} ->
        %{conn_state|error: {:connection_error, :protocol_error}}
      {:error, error} ->
        %{conn_state|error: {:connection_error, error}}

      _ ->
        data = conn_state.cont_buffer <> data
        conn_state = %{conn_state|cont_stream_id: nil, cont_buffer: nil}

        case Headers.decode(data, decode_context) do
          {:error, error} -> 
            %{conn_state|error: {:connection_error, error}}

          {:ok, headers, decode_context} -> 
 
            content_length = Keyword.get(headers, :'content-length') |> Sardines.Headers.parse_content_length
            stream = %{stream|state: new_state, content_length: content_length}
            streams = Map.put(conn_state.streams, stream.id, stream)
            %{conn_state|streams: streams, decode_context: decode_context}
        end
    end
  end

 
  # Push promise

  def event(:push_promise, stream, flags, {promised_id, data}, %{cont_stream_id: cont_stream_id} = conn_state) do
    new_state = FSM.next_state(:headers, stream.state, flags)
    conn_state = handle_concurrency_count(stream.state, new_state, conn_state)
    case new_state do
      {:cont, then_state} when is_nil(cont_stream_id) ->
        %{conn_state|cont_stream_id: stream.id, cont_buffer: data}
      {:cont, then_state} -> 
        %{conn_state|error: {:connection_error, :protocol_error}}
      {:error, error} ->
        %{conn_state|error: {:connection_error, error}}
      _ ->
        streams = Map.put(conn_state.streams, stream.id, %{stream|state: new_state})
        %{conn_state|streams: streams, cont_stream_id: stream.id, cont_buffer: data}
    end
  end


  # Priority

  def event(:priority, _, %{id: id}, {_, stream_dependency, _}, conn_state) when stream_dependency == id, 
    do: %{conn_state|error: {:connection_error, :protocol_error}}
  def event(:priority, _, _, data, conn_state), do: conn_state


  # Data

  def event(:data, stream, flags, data, conn_state) do
    new_state = FSM.next_state(:data, stream.state, flags)
    conn_state = handle_concurrency_count(stream.state, new_state, conn_state)
    %{buffered_content_length: buffered_content_length, content_length: content_length} = stream
    
   # flow control byte size
    case new_state do
      s when s in [:open, :half_closed] and not is_nil(content_length) and buffered_content_length + byte_size(data) > content_length ->
        %{conn_state|error: {:connection_error, :protocol_error}}
      s when s in [:open, :half_closed] ->
        stream = %{stream|state: :half_closed, buffered_content_length: buffered_content_length + byte_size(data)}
        streams = %{conn_state.streams|stream.id => stream}
        %{conn_state|streams: streams}
      {:error, error} ->
        %{conn_state|error: {:connection_error, error}}
    end
  end


  # Reset

  def event(:rst_stream, stream, _, data, conn_state) do
    streams = %{conn_state.streams|stream.id => %{stream|state: :closed}}
    %{conn_state|streams: streams}
  end


  # Window update

  def event(:window_update, _, _, 0, conn_state),
    do: %{conn_state|error: {:connection_error, :flow_control_error}}

  def event(:window_update, %{window_size: window_size}, _, size, conn_state)
  when window_size+size > 2147483647,
  do: %{conn_state|error: {:connection_error, :flow_control_error}}

  def event(:window_update, :idle, _, size, conn_state),
    do: %{conn_state|error: {:connection_error, :protocol_error}}

  def event(:window_update, stream, flags, size, conn_state) do
    new_state = FSM.next_state(:data, stream.state, flags)
    case new_state do
      {:error, error} ->
        %{conn_state|error: {:connection_error, error}}
      _ ->
        streams = %{conn_state.streams|stream.id => %{stream|window_size: stream.window_size+size}}
        %{conn_state|streams: streams}
    end
  end


  # Concurrency count updates

  def handle_concurrency_count(:open, :half_closed, conn_state), do: conn_state
  def handle_concurrency_count(:open, _, %{concurrent_count: concurrent_count} = conn_state), 
    do: %{conn_state|concurrent_count: concurrent_count-1}
  def handle_concurrency_count(:half_closed, _, %{concurrent_count: concurrent_count} = conn_state), 
    do: %{conn_state|concurrent_count: concurrent_count-1}
  def handle_concurrency_count(_, :open, %{concurrent_count: concurrent_count} = conn_state), 
    do: %{conn_state|concurrent_count: concurrent_count+1}
  def handle_concurrency_count(_, :half_closed, %{concurrent_count: concurrent_count} = conn_state), 
    do: %{conn_state|concurrent_count: concurrent_count+1}
  def handle_concurrency_count(_, _, conn_state), do: conn_state
end
