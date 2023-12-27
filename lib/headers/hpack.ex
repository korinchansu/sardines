defmodule Sardines.Headers.HPACK do
  use Bitwise

  alias Sardines.Headers.Huffman
  alias Sardines.Headers.HPACK.Table

  defstruct [table: [], size: 0, max_size: 4096]

  def encode([], acc, s), do: {acc, s}

  def encode([{name, value}|headers], acc, %{table: table} = s) do
    case Table.search(name, value, table) do
      {:found, index} -> # field match
        bin = << 1 :: 1, encode_prefixed_integer(1, index) :: bits >>
        encode(headers, << acc :: bits, bin :: bits >>, s)
      {:found_key, at_index} -> # name match
        s = Table.add(name, value, s)
        bin = << 0 :: 1, 1 :: 1, encode_prefixed_integer(2, at_index) :: bits, encode_string_literal(value) :: binary >>
        encode(headers, << acc :: bits, bin :: bits >>, s)
      :nomatch ->
        s = Table.add(name, value, s)
        bin = << 0 :: 1, 1 :: 1, 0 :: 6, encode_string_literal(name) :: binary, encode_string_literal(value) :: binary >>
        encode(headers, << acc :: bits, bin :: bits >>, s)
    end
  end

  def encode_string_literal(bin) do
    data = Huffman.encode(bin)
    length = byte_size(data)
    << 1 :: 1, encode_prefixed_integer(1, length) :: bits, data :: binary >>
  end

  def encode_prefixed_integer(2, integer) when integer < 63, do: << integer :: 6 >>
  def encode_prefixed_integer(2, integer), 
    do: << 63 :: 6, encode_multi_octet_integer(integer - 63) :: bits >>
  def encode_prefixed_integer(1, integer) when integer < 127, do: << integer :: 7 >>
  def encode_prefixed_integer(1, integer), 
    do: << 127 :: 7, encode_multi_octet_integer(integer - 127) :: bits >>

  def encode_multi_octet_integer(integer) when integer < 128, do: << 0 :: 1, integer :: 7 >>
  def encode_multi_octet_integer(integer), 
    do: << 1 :: 1, integer :: 7,  encode_multi_octet_integer(integer >>> 7) :: binary >>


  def decode(<< >>, s, acc), do: {:ok, Enum.reverse(acc), s}

  # Indexed header field

  def decode(<< 1 :: 1, rest :: bits >>, %{table: table} = s, acc) do
    {index, rest} = decode_prefixed_integer(1, rest)
    decode(rest, s, [Table.lookup(index, table)|acc])
  end


  ## Literal Header Field with Incremental Indexing

  # Name
  def decode(<< 0 :: 1, 1 :: 1, 0 :: 6, rest :: bits >>, s, acc) do
    {name, rest} = decode_string_literal(rest)
    {value, rest} = decode_string_literal(rest)
    s = Table.add(name, value, s)
    decode(rest, s, [{String.to_atom(name), value}|acc])
  end

  # Indexed Name
  def decode(<< 0 :: 1, 1 :: 1, rest :: bits >>, %{table: table} = s, acc) do
    {index, rest} = decode_prefixed_integer(2, rest)
    {value, rest} = decode_string_literal(rest)
    {name, _} = Table.lookup(index, table) 
    s = Table.add(Atom.to_string(name), value, s)
    decode(rest, s, [{name, value}|acc])
  end


  ## Literal Header Field without Indexing

   # New Name
  def decode(<< 0 :: 4, 0 :: 4, rest :: bits >>, s, acc) do
    {name, rest} = decode_string_literal(rest)
    {value, rest} = decode_string_literal(rest)
    decode(rest, s, [{String.to_atom(name), value}|acc])
  end
 
  # Indexed Name 
  def decode(<< 0 :: 4, rest :: bits >>, %{table: table} = s, acc) do
    {index, rest} = decode_prefixed_integer(4, rest)
    {value, rest} = decode_string_literal(rest)
    {name, _} = Table.lookup(index, table)
    decode(rest, s, [{name, value}|acc])
  end
  

  ## Literal Header Field Never Indexed

  # New Name
  def decode(<< 0 :: 3, 1 :: 1, 0 :: 4, rest :: bits >>, s, acc) do
    {name, rest} = decode_string_literal(rest)
    {value, rest} = decode_string_literal(rest)
    decode(rest, s, [{String.to_atom(name), value}|acc])
  end
   
  # Indexed Name
  def decode(<< 0 :: 3, 1 :: 1, rest :: bits >>, %{table: table} = s, acc) do
    {index, rest} = decode_prefixed_integer(4, rest)
    {value, rest} = decode_string_literal(rest)
    {name, _} = Table.lookup(index, table)
    decode(rest, s, [{String.to_atom(name), value}|acc])
  end


  # Maximum Dynamic Table Size Change
  def decode(<< 0 :: 2, 1 :: 1, rest :: bits >>, s, []) do
    {max_size, rest} = decode_prefixed_integer(3, rest)
    s = Table.resize(max_size, s)
    decode(rest, s, [])
  end


  for prefix_size <- 1..4 do
    integer_size = 8 - prefix_size
    max_value = trunc(:math.pow(2, integer_size))-1

    def decode_prefixed_integer(unquote(prefix_size), << integer :: unquote(integer_size), rest :: bits >>) do
      case integer do
        unquote(max_value) -> 
          decode_multi_octet_integer(rest, unquote(max_value), 0)
        _ -> 
          {integer, rest}
      end
    end
  end


  def decode_multi_octet_integer(<< continue :: 1, value :: 7, rest :: bits >>, acc, m) do
    new_value = acc + (value <<< m)
    case continue do
      1 -> decode_multi_octet_integer(rest, new_value, m+7)
      0 -> {new_value, rest}
    end
  end

  def decode_string_literal(<< huffman_flag :: 1, rest :: bits >>) do
    {length, rest} = decode_prefixed_integer(1, rest)
    << value :: binary - size(length), rest :: binary >> = rest
    case huffman_flag do
      1 -> {Huffman.decode(value), rest}
      0 -> {value, rest}
    end
  end
end
