defmodule Sardines.Frame.Flag do
  @moduledoc false

  use Bitwise

  @end_stream   0x1
  @ack          0x1
  @end_headers  0x4
  @padded       0x8
  @priority     0x20


  defmacro has_end_stream(flags) do
    quote do
      (unquote(flags) &&& unquote(@end_stream)) == unquote(@end_stream)
    end
  end

  defmacro has_ack(flags) do
    quote do
      (unquote(flags) &&& unquote(@ack)) == unquote(@ack)
    end
  end

  defmacro has_end_headers(flags) do
    quote do
      (unquote(flags) &&& unquote(@end_headers)) == unquote(@end_headers)
    end
  end

  defmacro has_padding(flags) do
    quote do
      (unquote(flags) &&& unquote(@padded)) == unquote(@padded)
    end
  end

  defmacro has_priority(flags) do
    quote do
      (unquote(flags) &&& unquote(@priority)) == unquote(@priority)
    end
  end


  for {flag_name, flag} <- [end_stream: @end_stream, ack: @ack, 
                            end_headers: @end_headers, padded: @padded, 
                            priority: @priority] do

    def encode_flags([unquote(flag_name)|flags], acc), 
      do: encode_flags(flags, acc ||| unquote(flag)) 

  end
  def encode_flags([], acc), do: acc 

end
