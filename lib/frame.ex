defmodule Sardines.Frame do
  @moduledoc false

  require Integer

  import Sardines.Frame.Flag

  @frames   [data:                    0x0, 
             headers:                 0x1, 
             priority:                0x2, 
             rst_stream:              0x3,
             settings:                0x4, 
             push_promise:            0x5, 
             ping:                    0x6, 
             goaway:                  0x7,
             window_update:           0x8, 
             continuation:            0x9]
 
  @settings [header_table_size:       0x1,
             enable_push:             0x2,
             max_concurrent_streams:  0x3,
             initial_window_size:     0x4,
             max_frame_size:          0x5,
             max_header_list_size:    0x6]

  @errors   [no_error:                0x0,
             protocol_error:          0x1,
             internal_error:          0x2,
             flow_control_error:      0x3,
             settings_timeout:        0x4,
             stream_closed:           0x5,
             frame_size_error:        0x6,
             refused_stream:          0x7,
             cancel:                  0x8,
             compression_error:       0x9,
             connect_error:           0xa,
             enhance_your_calm:       0xb,
             inadequate_security:     0xc,
             http_1_1_required:       0xd]


  # Encoding

  def encode_frame(length, type, flags, stream_id, data) do
    << length :: 24, type :: 8, encode_flags(flags, 0) :: 8, 0 :: 1, stream_id :: 31, data :: bits >>
  end

  def encode_data(%{padded: pad_length}, flags, stream_id, data) do
    length = byte_size(data)
    data_length = length + pad_length + 1
    padding = Enum.reduce(1..pad_length, << >>, fn _, acc -> acc <> "0" end)
    data = << pad_length :: 8, data :: binary-size(length), padding :: binary-size(pad_length) >>
    encode_frame(data_length, 0, flags, stream_id, data)
  end

  def encode_data(flags, stream_id, data),
    do: encode_frame(byte_size(data), 0, flags, stream_id, data)

  def encode_headers(%{padded: pad_length, priority: {exclusive, stream_dependency, weight}}, flags, stream_id, headers) do
    length = byte_size(headers)
    data_length = length + pad_length + 1
    padding = Enum.reduce(1..pad_length, << >>, fn _, acc -> acc <> "0" end)
    headers = << pad_length :: 8, headers :: binary-size(length), padding :: binary-size(pad_length) >>
    data = << exclusive :: 1, stream_dependency :: 31, weight :: 8 >> <> headers
    encode_frame(data_length, 1, flags, stream_id, data)
  end

  def encode_headers(%{padded: pad_length}, flags, stream_id, headers) do
    length = byte_size(headers)
    data_length = length + pad_length + 1
    padding = Enum.reduce(1..pad_length, << >>, fn _, acc -> acc <> "0" end)
    headers = << pad_length :: 8, headers :: binary-size(length), padding :: binary-size(pad_length) >>
    encode_frame(data_length, 1, flags, stream_id, headers)
  end

  def encode_headers(%{priority: {exclusive, stream_dependency, weight}}, flags, stream_id, headers) do
    data = << exclusive :: 1, stream_dependency :: 31, weight :: 8 >> <> headers
    encode_frame(byte_size(headers), 1, flags, stream_id, data)
  end

  def encode_headers(flags, stream_id, headers), 
    do: encode_frame(byte_size(headers), 1, flags, stream_id, headers)

  def encode_continuation(flags, stream_id, headers),
    do: encode_frame(byte_size(headers), 9, flags, stream_id, headers)

  def encode_priority(stream_id, exclusive, stream_dependency, weight) do
    data = << exclusive :: 1, stream_dependency :: 31, weight :: 8 >>
    encode_frame(byte_size(data), 2, [], stream_id, data)
  end

  def encode_settings(nil, flags), do: encode_frame(0, 4, flags, 0, "")
  def encode_settings(settings, flags) do 
    data = encode_settings_kv(settings, << >>)
    encode_frame(byte_size(data), 4, flags, 0, data)
  end

  def encode_settings_kv([], acc), 
    do: acc

  for {setting_name, setting_code} <- @settings do
    def encode_settings_kv([{unquote(setting_name), value}|settings], acc) do
      encode_settings_kv(settings, acc <> << unquote(setting_code) :: 16, value :: 32>>)
    end
  end

  def encode_push_promise(flags, stream_id, promised_stream_id, headers),
    do: encode_frame(byte_size(headers), 5, flags, stream_id, headers)

  def encode_ping(flags, 0), 
    do: encode_frame(8, 6, flags, 0, << 0 :: 64 >>)

  def encode_ping(flags, payload), 
    do: encode_frame(8, 6, flags, 0, payload)


  for {error, error_code} <- @errors do
    def encode_rst_stream(stream_id, unquote(error)),
      do: encode_frame(4, 3, [], stream_id, << unquote(error_code) :: 32 >>)
    
    def encode_goaway(last_stream_id, unquote(error), debug_data) do
      length = byte_size(debug_data)
      msg = << 0 :: 1, last_stream_id :: 31, unquote(error_code) :: 32, debug_data :: binary-size(length) >>
      encode_frame(length+8, 7, [], 0, msg)
    end
  end

  def encode_window_update(window_increment_size), 
    do: encode_frame(4, 8, [], 0, << 0 :: 1, window_increment_size :: 31 >>)

  def encode_window_update(stream_id, window_increment_size), 
    do: encode_frame(4, 8, [], stream_id, << 0 :: 1, window_increment_size :: 31 >>)



  # Decoding

  def decode(<< length :: 24, type :: 8, flags :: 8, _r :: 1, stream_id :: 31, rest :: bits >>),
    do: decode_frame(type, length, flags, stream_id, rest)

  def decode_frame(_, _, _, stream_id, _) when stream_id != 0 and Integer.is_even(stream_id), 
  do: {:error, {:connection_error, :protocol_error}} 

  for {frame_name, frame_id} <- @frames do
    def decode_frame(unquote(frame_id), length, flags, stream_id, value) do
      unquote(String.to_atom("decode_#{frame_name}"))(length, flags, stream_id, value)
    end
  end

  def decode_frame(frame_id, length, flags, stream_id, value) do
    # unknown frame, ignore it and return rest 
    << _unknown_payload :: binary-size(length), rest :: bits >> = value 
    {:unknown_frame, rest}
  end

  def decode_frame(_, _, _, _, _), do: {:error, {:connection_error, :protocol_error}}


  def decode_data(length, flags, _, << pad_length :: 8, _ :: bits >>) when has_padding(flags) and pad_length >= length, 
    do: {:error, {:connection_error, :protocol_error}}
  def decode_data(length, flags, stream_id, << pad_length :: 8, bin :: bits >>) when has_padding(flags) do
    data_length = length - pad_length - 1
    << data :: binary-size(data_length), _padding :: binary-size(pad_length), rest :: bits >> = bin
    {:data, stream_id, flags, data, rest}
  end
  def decode_data(length, flags, stream_id, bin) do
    << data :: binary-size(length), rest :: bits >> = bin
    {:data, stream_id, flags, data, rest}
  end


  def decode_headers(length, flags, _, << pad_length :: 8, _ :: bits >>) when has_padding(flags) and pad_length > length, 
    do: {:error, {:connection_error, :protocol_error}}
  def decode_headers(length, flags, stream_id, << pad_length :: 8, bin :: bits >>) when has_padding(flags) and has_priority(flags) do
    data_length = (length - pad_length) - 6
    << e :: 1, stream_dependency :: 31, weight :: 8, bin :: bits >> = bin
    << data :: binary-size(data_length), _ :: binary-size(pad_length), rest :: bits >> = bin
    {:headers, stream_id, flags, {{e, stream_dependency, weight}, data}, rest}
  end
  def decode_headers(length, flags, stream_id, bin) when has_priority(flags) do
    << e :: 1, stream_dependency :: 31, weight :: 8, bin :: bits >> = bin
    << header_block_fragment :: binary-size(length), rest :: bits >> = bin
    {:headers, stream_id, flags, {{e, stream_dependency, weight}, header_block_fragment}, rest}
  end
  def decode_headers(length, flags, stream_id, << pad_length :: 8, bin :: bits >>) when has_padding(flags) do
    data_length = length - pad_length - 1
    << data :: binary-size(data_length), _padding :: binary-size(pad_length), rest :: bits >> = bin
    {:headers, stream_id, flags, data, rest}
  end
  def decode_headers(length, flags, stream_id, bin) do
    << header_block_fragment :: binary-size(length), rest :: bits >> = bin
    {:headers, stream_id, flags, header_block_fragment, rest}
  end


  def decode_priority(5, _, stream_id, << e :: 1, stream_dependency :: 31, weight :: 8, rest :: bits >>),
    do: {:priority, stream_id, 0, {e, stream_dependency, weight}, rest}
  def decode_priority(_, _, _, _),
    do: {:error, {:connection_error, :frame_size_error}}

  def decode_rst_stream(4, _, stream_id, << error_code :: 32, rest :: bits >>),
    do: {:rst_stream, stream_id, 0, error_code, rest}
  def decode_rst_stream(_, _, _, _),
    do: {:error, {:connection_error, :frame_size_error}}

  def decode_push_promise(length, flags, stream_id, << pad_length :: 8, bin :: bits >>) when has_padding(flags) do
    data_length = (length - pad_length) - 5
    << _r :: 1, promised_stream_id :: 31, bin :: bits >> = bin
    << data :: binary-size(data_length), _ :: binary-size(pad_length), rest :: bits >> = bin
    {:push_promise, stream_id, flags, {promised_stream_id, data}, rest}
  end

  def decode_push_promise(length, flags, stream_id, bin) do
    data_length = length - 5
    << _r :: 1, promised_stream_id :: 31, header_block_fragment :: binary-size(data_length), rest :: bits >> = bin
    {:push_promise, stream_id, flags, {promised_stream_id, header_block_fragment}, rest}
  end


  def decode_ping(8, flags, 0, bin) do
    << payload :: binary-size(8), rest :: bits >> = bin
    {:ping, flags, payload, rest}
  end
  def decode_ping(_, _, 0, _),
    do: {:error, {:connection_error, :frame_size_error}}
  def decode_ping(_, _, _, _),
    do: {:error, {:connection_error, :protocol_error}}


  def decode_goaway(length, _, 0, bin) do 
    data_length = length - 8
    << _r :: 1, last_stream_id :: 31, error_code :: 32, bin :: bits >> = bin
    << additional_debug_data :: binary-size(data_length), rest :: bits >> = bin
    {:goaway, 0, {last_stream_id, error_code, additional_debug_data}, rest}
  end

  def decode_goaway(_, _, _, _),
    do: {:error, {:connection_error, :protocol_error}}



  def decode_window_update(_, _, _, << _ :: 1, 0 :: 31, _ :: bits >>),
    do: {:error, {:connection_error, :protocol_error}}

  def decode_window_update(length, _, _, _) when rem(length, 4) > 0 do
    {:error, {:connection_error, :frame_size_error}}
  end

  def decode_window_update(_, _, 0, << _r :: 1, window_size_increment :: 31, rest :: bits >>),
    do: {:window_update, 0, window_size_increment, rest}

  def decode_window_update(_, _, stream_id, << _r :: 1, window_size_increment :: 31, rest :: bits >>),
    do: {:window_update, stream_id, 0, window_size_increment, rest}


  def decode_continuation(length, flags, stream_id, bin) do
    << header_block_fragment :: binary-size(length), rest :: bits >> = bin
    {:continuation, stream_id, flags, header_block_fragment, rest}
  end


  def decode_settings(length, _, _, _) when rem(length, 6) > 0,
    do: {:error, {:connection_error, :frame_size_error}}
  def decode_settings(length, flags, _, _) when length > 0 and has_ack(flags),
    do: {:error, {:connection_error, :protocol_error}}

  def decode_settings(length, flags, stream_id, value) when has_ack(flags),
    do: {:settings, flags, %{}, value}
  def decode_settings(length, flags, 0, value) do
    case handle_decode_settings(value, length, []) do
      {:error, msg} = e -> e
      {acc, rest} ->
        {:settings, flags, Enum.into(acc, %{}), rest}
    end
  end
  def decode_settings(_, _, _, _),
    do: {:error, {:connection_error, :protocol_error}}
 
  def handle_decode_settings(bin, 0, acc), do: {acc, bin}
  def handle_decode_settings(<< 2 :: 16, value :: 32, _ :: bits >>, _, _) when not value in [0,1], 
    do: {:error, {:connection_error, :protocol_error}}
  def handle_decode_settings(<< 4 :: 16, value :: 32, _ :: bits >>, _, _) when value > 2147483647, 
    do: {:error, {:connection_error, :flow_control_error}} 
  def handle_decode_settings(<< 5 :: 16, value :: 32, _ :: bits >>, _, _) when value < 16384, 
    do: {:error, {:connection_error, :protocol_error}}
  def handle_decode_settings(<< 5 :: 16, value :: 32, _ :: bits >>, _, _) when value > 16777215, 
    do: {:error, {:connection_error, :protocol_error}} 

  for {setting_type_name, setting_type} <- @settings do
    def handle_decode_settings(<< unquote(setting_type) :: 16, data :: 32, rest :: bits >>, length, acc),
      do: handle_decode_settings(rest, length-6, [{unquote(setting_type_name), data}|acc])
  end
end
