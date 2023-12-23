sardines
====


#### lengthy example:

```elixir
  alias Sardines.Frame
  alias Sardines.Stream

  @settings_timeout 5

  def log(msg) do
    :error_logger.format('~p', [msg])
  end

  def handshake(%{socket: socket, socket_mode: socket_mode, 
                  settings: settings, buffer: << length :: 24, rest :: bits >>} = conn_state) 
  when length+6 <= byte_size(rest) do
    case Frame.decode(conn_state.buffer) do
      {:settings, flags, client_settings, rest} ->
        socket_mode.send(socket, Frame.encode_settings(nil, [:ack]) <> Frame.encode_settings(nil, []))
        ref = Process.send_after(self, :settings_timeout, @settings_timeout)
        new_settings = Map.merge(settings, client_settings)
        loop(%{conn_state|settings: new_settings, buffer: rest, sent_settings: [{ref, %{}}]})
      _ ->
        loop(%{conn_state|error: {:connection_error, :protocol_error}})
    end
  end

  def handshake(%{socket: socket, buffer: buffer} = conn_state) do
    :inet.setopts(socket, active: :once)
    receive do
      {:tcp, ^socket, msg} ->
        handshake(%{conn_state|buffer: conn_state.buffer <> msg})
      {:closed, socket} -> 
        :ok
    after @settings_timeout ->
      loop(%{conn_state|error: {:connection_error, :protocol_error}})
    end
  end

  def loop(%{socket_mode: socket_mode, socket: socket, error: error} = conn_state) 
  when not is_nil(error) do
    case error do
      {:connection_error, error_code} ->
        frame = Frame.encode_goaway(conn_state.last_stream_id, error_code, << >>)
        socket_mode.send(socket, frame)
      {:stream_error, stream_id, error_code} ->
        frame = Frame.encode_rst_stream(stream_id, error_code)
        socket_mode.send(socket, frame)
        loop(%{conn_state|error: nil})
    end
  end

  def loop(%{buffer: << length :: 24, rest :: bits >>, 
             settings: %{max_frame_size: max_frame_size}} = conn_state) 
  when length > max_frame_size do
    log("EXCEEDED MAX FRAME SIZE <++++++++++++++++++++++++")
    %{conn_state|error: {:connection_error, :frame_size_error}} |> loop
  end

  def loop(%{streams: streams, buffer: << length :: 24, rest :: bits >>, cont_stream_id: cont_stream_id} = conn_state) 
  when byte_size(rest) >= length+6 do
    case Frame.decode(conn_state.buffer) do

      {type, flags, data, rest} = f->
        log(f)
        # Unimplemented here
        Connection.event(type, flags, data, %{conn_state|buffer: rest})

      {type, stream_id, flags, data, rest} = f ->
        stream = Map.get(streams, stream_id, {:new_stream, stream_id})
        Stream.event(type, stream, flags, data, %{conn_state|buffer: rest})

      {:unknown_frame, rest} when cont_stream_id != nil ->
        %{conn_state|error: {:connection_error, :protocol_error}}

      {:unknown_frame, rest} ->
        %{conn_state|buffer: rest}

      {:error, error} -> 
        %{conn_state|error: error}
    end
    |> loop
  end

  def loop(%{socket: socket, socket_mode: socket_mode, buffer: buffer} = conn_state) do
    :inet.setopts(socket, active: :once)
    receive do
      {:tcp, ^socket, msg} ->
        loop(%{conn_state|buffer: buffer <> msg}) 
      :settings_timeout ->
        loop(%{conn_state|error: {:connection_error, :settings_timeout}})
      {:closed, socket} -> :ok
    after 1500 ->
        log(buffer)
      
        loop(%{conn_state|error: {:connection_error, :no_error}})
    end
  end



  
```
