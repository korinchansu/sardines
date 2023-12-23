defmodule Sardines.Stream.FSM do

  import Sardines.Frame.Flag, only: :macros

  defp cont(state), do: {:cont, state}
  defp err(reason), do: {:error, reason}


  def next_state(:headers, :idle, f) when has_end_headers(f) and has_end_stream(f),     do: :half_closed
  def next_state(:headers, :idle, f) when has_end_stream(f),                            do: cont(:half_closed)
  def next_state(:headers, :idle, f) when has_end_headers(f),                           do: :open
  def next_state(:headers, :idle, _),                                                   do: cont(:open)

  def next_state(:headers, :reserved, f) when has_end_headers(f) and has_end_stream(f), do: :closed
  def next_state(:headers, :reserved, f) when has_end_stream(f),                        do: cont(:closed)
  def next_state(:headers, :reserved, f) when has_end_headers(f),                       do: :half_closed
  def next_state(:headers, :reserved, _),                                               do: cont(:half_closed)  

  def next_state(:headers, _, f) when not has_end_stream(f),                            do: err(:protocol_error)

  def next_state(:continuation, {:cont, then_state}, f) when has_end_headers(f),        do: then_state
  def next_state(:continuation, {:cont, then_state}, _),                                do: cont(then_state)
  def next_state(:continuation, _, _),                                                  do: err(:protocol_error)

  def next_state(:priority, state, _),                                                  do: state

  def next_state(:data, :open, f) when has_end_stream(f),                               do: :half_closed
  def next_state(:data, :open, _),                                                      do: :open

  def next_state(:push_promise, :idle, f) when has_end_headers(f),                      do: :reserved
  def next_state(:push_promise, :idle, _),                                              do: cont(:reserved)

  def next_state(:rst_stream, :idle, _),                                                do: err(:protocol_error)
  def next_state(:rst_stream, _, _),                                                    do: :closed

  def next_state(:window_update, :half_closed, _),                                      do: :half_closed
  def next_state(:window_update, :closed, _),                                           do: :closed

  def next_state(_, :closed, _),                                                        do: err(:stream_closed)
  def next_state(_, :half_closed, _),                                                   do: err(:stream_closed)

  def next_state(_, _, _),                                                              do: err(:protocol_error)
end
