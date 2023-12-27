defmodule Sardines.Headers do

  alias Sardines.Headers.HPACK

  @pseudo_headers [":authority", ":method", ":path", ":scheme"]

  def encode(headers, s), 
    do: HPACK.encode(headers, << >>, s)

  def decode(bin, s) do
    try do
      {:ok, headers, s} = HPACK.decode(bin, s, [])

      case validate(headers) do
        false   -> {:error, :protocol_error}
        true    -> {:ok, headers, s}
      end
    rescue
      _ -> {:error, :compression_error}
    end
  end

  def log(msg),
    do: :error_logger.format('~p', [msg])

  def validate(headers) do
    cond do
      not has_no_connection_header(headers)     -> false
      not has_valid_transfer_encoding(headers)  -> false
      not has_lowercase_headers(headers)        -> false
      not valid_pseudo_headers(headers)         -> false
      true                                      -> true
    end
  end

  def has_no_connection_header(headers) do
    not Keyword.has_key?(headers, :"connection")
  end

  def has_valid_transfer_encoding(headers) do
    te = Keyword.get(headers, :"transfer-encoding")
    te = Keyword.get(headers, :"te", te)
    te == "trailers" or te == nil
  end

  def has_lowercase_headers(headers) do
    not Enum.any?(headers, fn {k, _} -> has_uppercase?(Atom.to_string(k)) end)
  end

  def valid_pseudo_headers(headers) do
    header_keys = Enum.map(headers, fn {k, _} -> Atom.to_string(k) end)
    cond do
      not has_headers_ordered_correctly(header_keys)    -> false
      not has_recognized_pseudo_headers(header_keys)    -> false
      not has_one_entry_per_pseudo_header(header_keys)  -> false
      true                                              -> true
    end
  end

  def has_headers_ordered_correctly(headers) do
    [first_group|tail] = 
      Enum.chunk_by(headers, fn k -> String.at(k, 0) == ":" end)
    wrong_start = Enum.any?(first_group, fn k -> String.at(k, 0) != ":" end)
    not wrong_start and Enum.count(tail) < 2 
  end

  def has_recognized_pseudo_headers(headers) do
    not Enum.any?(headers, fn k -> String.at(k, 0) == ":" and not k in @pseudo_headers end)
  end

  def has_one_entry_per_pseudo_header(headers) do
    not Enum.any?(@pseudo_headers,  fn k ->
      Enum.count(headers, fn key -> k == key end) != 1 
    end)
  end

@headers [
  "accept-charset",
  "accept-encoding",
  "accept-language",
  "accept-ranges",
  "accept",
  "access-control-allow-origin",
  "age",
  "allow",
  "authorization",
  "cache-control",
  "content-disposition",
  "content-encodinggzip",
  "content-language",
  "content-length",
  "content-location",
  "content-ranges",
  "content-type",
  "cookie",
  "date",
  "etag",
  "expect",
  "expires",
  "from",
  "host",
  "if-match",
  "if-modified-since",
  "if-none-match",
  "if-ranges",
  "if-unmodified-since",
  "last-modified",
  "link",
  "location",
  "max-forwards",
  "proxy-authenticate",
  "proxy-authorization",
  "range",
  "referer",
  "refresh",
  "retry-after",
  "server",
  "set-cookie_value",
  "strict-transport-security",
  "transfer-encodinggzip",
  "user-agent",
  "vary",
  "via",
  "www-authenticate"
]

  for header_name <- @headers do
    def header(unquote(header_name), value), 
      do: unquote("parse_#{header_name}").(value)
  end
  def header(_, value), do: value
  


  # Value Parsers 

  def parse_accept(bin), 
    do: handle_accept(header_value(bin, [], << >>), [])
  
  def handle_accept([], acc), do: acc
  def handle_accept([{type, opts}|headers], acc) do
      {q, opts} = quality_opt(opts, 1000, [])
      handle_accept(headers, [{type, q, opts}|acc])
  end
  
  
  def parse_accept_charset(bin), 
    do: handle_accept_charset(header_value(bin, [], << >>), [])
  
  def handle_accept_charset([], acc), do: acc
  def handle_accept_charset([{type, opts}|headers], acc) do
      {q, opts} = quality_opt(opts, 1000, [])
      handle_accept_charset(headers, [{type, q, opts}|acc])
  end
  
  
  def parse_accept_encoding(bin), 
    do: handle_accept_encoding(header_value(bin, [], << >>), [])
  
  def handle_accept_encoding([], acc), do: acc
  def handle_accept_encoding([{type, opts}|headers], acc) do
      {q, opts} = quality_opt(opts, 1000, [])
      handle_accept_encoding(headers, [{type, q, opts}|acc])
  end
  
  
  def parse_accept_language(bin), 
    do: handle_accept_language(header_value(bin, [], << >>), [])
  def handle_accept_language([], acc), do: acc
  def handle_accept_language([{type, opts}|headers], acc) do
      {q, opts} = quality_opt(opts, 1000, [])
      handle_accept_language(headers, [{type, q, opts}|acc])
  end
  
  
  def parse_authorization(<<"Bearer ", rest :: bits>>), 
    do: {:bearer, rest}
  def parse_authorization(<<"Digest ", rest :: bits>>), 
    do: {:digest, header_kv(rest, [], << >>)}
  def parse_authorization(<<"Basic ", rest :: bits>>) do
    [username, password] = String.split(Base.decode64(rest), ":") 
    {:basic, username, password}
  end
  
  
  def parse_connection(<<"close">>), do: :close
  def parse_connection(<<"keep-alive">>), do: :"keep-alive"
  def parse_connection(bin), do: String.downcase(bin)
  
  
  def parse_content_length(nil), do: nil
  def parse_content_length(bin), do: String.to_integer(bin)
  
  
  def parse_content_type(bin), 
    do: handle_content_type(header_value(bin, [], << >>), [])
  def handle_content_type([], acc), do: acc
  def handle_content_type([{type, opts}|headers], acc), 
    do: handle_content_type(headers, [{type, opts}|acc])
  
  
  def parse_cookie(bin), do: handle_cookies(bin, [], << >>)
  
  def handle_cookies(<<?;, rest :: bits>>, cookies, cookie_key),
    do: handle_cookies(rest, [cookie_key|cookies], << >>)
  def handle_cookies(<<?=, rest :: bits>>, cookies, cookie_key),
    do: handle_cookie_value(rest, cookies, cookie_key, << >>)
  def handle_cookies(<<char, rest :: bits>>, cookies, cookie_key),
    do: handle_cookies(rest, cookies, <<cookie_key :: binary, char>>)
  
  def handle_cookie_value(<< >>, cookies, cookie_key, cookie_value),
    do: Enum.reverse([{cookie_key, cookie_value} |cookies])
  def handle_cookie_value(<<?;, rest :: bits>>, cookies, cookie_key, cookie_value),
    do: handle_cookies(rest, [{cookie_key, cookie_value}|cookies], << >>)
  def handle_cookie_value(<<char, rest :: bits>>, cookies, cookie_key, cookie_value),
    do: handle_cookie_value(rest, cookies, cookie_key, <<cookie_value :: binary, char>>)
  
  
  def parse_expect(<<"100-continue">>), do: :continue
  def parse_expect(<<"100-", bin :: bits>>), do: parse_expect(String.downcase(bin), nil)
  def parse_expect(<<"continue">>, _), do: :continue
  
  
  def parse_if_match(bin), do: etag(bin, [], nil, << >>)
  
  def parse_if_none_match(bin), do: etag(bin, [], nil, << >>)
  
  def parse_if_modified_since(bin), do: Coltrane.Decoder.Datetime.parse(bin)
  
  def parse_if_unmodified_since(bin), do: Coltrane.Decoder.Datetime.parse(bin)
  
  def parse_range(bin), do: range(bin, << >>)
  
  def parse_transfer_encoding(bin), do: header_list(bin, [], << >>)
  
  def parse_upgrade(bin), do: header_list(String.downcase(bin), [], << >>)
  
  def parse_x_forwarded_for(bin), do: header_list(bin, [], << >>)
  
  
  
  ## Header Parser Helpers
  
  def header_list(<< >>, acc, << >>), do: acc
  def header_list(<< >>, acc, val), do: [val|acc]
  def header_list(<<?\s, rest :: bits>>, acc, val), 
    do: header_list(rest, acc, val)
  def header_list(<<?\t, rest :: bits>>, acc, val), 
    do: header_list(rest, acc, val)
  def header_list(<<?,, rest :: bits>>, acc, << >>), 
    do: header_list(rest, acc, << >>)
  def header_list(<<?,, rest :: bits>>, acc, val), 
    do: header_list(rest, [val|acc], << >>)
  def header_list(<<char, rest :: bits>>, acc, val), 
    do: header_list(rest, acc, <<val :: binary, char>>)
  
  
  def header_kv(<<?,, rest :: bits>>, opts, opt_key), 
    do: header_kv(rest, [opt_key|opts], << >>)
  def header_kv(<<?=, rest :: bits>>, opts, opt_key), 
    do: header_kv_value(rest, opts, opt_key, << >>)
  def header_kv(<<char, rest :: bits>>, opts, opt_key), 
    do: header_kv(rest, opts, <<opt_key :: binary, char>>)
  
  def header_kv_value(<< >>, opts, opt_key, opt_value),
    do: Enum.reverse([{opt_key, opt_value}|opts])
  def header_kv_value(<<?,, rest :: bits>>, opts, opt_key, opt_value),
    do: header_kv(rest, [{opt_key, opt_value}|opts], << >>)
  def header_kv_value(<<?", rest :: bits>>, opts, opt_key, opt_value) do
      {rest, quoted_value} = quoted_value(rest, << >>)
      header_kv_value(rest, opts, opt_key, <<opt_value :: binary, quoted_value :: binary>>)
  end
  def header_kv_value(<<char, rest :: bits>>, opts, opt_key, opt_value),
    do: header_kv_value(rest, opts, opt_key, <<opt_value :: binary, char>>)
  
  def header_value(<< >>, acc, value),
    do: Enum.reverse([{value, []}|acc])
  def header_value(<<?;, rest :: bits>>, acc, value),
    do: header_opts(rest, acc, value, [], << >>)
  def header_value(<<char, rest :: bits>>, acc, value),
    do: header_value(rest, acc, <<value :: binary, char>>)
  
  
  def header_opts(<< >>, acc, value, opts, opt_key),
    do: Enum.reverse([{value, Enum.reverse([opt_key|opts])}|acc])
  def header_opts(<<?,, rest :: bits>>, acc, value, opts, opt_key),
    do: header_value(rest, [{value, [opt_key|opts]}|acc], << >>)
  def header_opts(<<?;, rest :: bits>>, acc, value, opts, opt_key),
    do: header_opts(rest, acc, value, [opt_key|opts], << >>)
  def header_opts(<<?=, rest :: bits>>, acc, value, opts, opt_key),
    do: header_opt_value(rest, acc, value, opts, opt_key, << >>)
  def header_opts(<<?\t, rest :: bits>>, acc, value, opts, opt_key),
    do: header_opts(rest, acc, value, opts, opt_key)
  def header_opts(<<?\s, rest :: bits>>, acc, value, opts, opt_key),
    do: header_opts(rest, acc, value, opts, opt_key)
  def header_opts(<<char, rest :: bits>>, acc, value, opts, opt_key),
    do: header_opts(rest, acc, value, opts, <<opt_key :: binary, char>>)
  
  def header_opt_value(<< >>, acc, value, opts, opt_key, opt_value), 
    do: Enum.reverse([{:value, Enum.reverse([{opt_key, opt_value}|opts])}|acc])
  def header_opt_value(<<?", rest :: bits>>, acc, value, opts, opt_key, opt_value) do
      {rest, quoted_value} = quoted_value(rest, << >>)
      header_opt_value(rest, acc, value, opts, opt_key, <<opt_value :: binary, quoted_value :: binary>>)
  end
  def header_opt_value(<<?;, rest :: bits>>, acc, value, opts, opt_key, opt_value),
    do: header_opts(rest, acc, value, [{opt_key, opt_value}|opts], << >>)
  def header_opt_value(<<?,, rest :: bits>>, acc, value, opts, opt_key, opt_value),
    do: header_value(rest, [{value, [{opt_key, opt_value}|opts]} |acc], << >>)
  def header_opt_value(<<char, rest :: bits>>, acc, value, opts, opt_key, opt_value),
    do: header_opt_value(rest, acc, value, opts, opt_key, <<opt_value :: binary, char>>)
  
  
  def range(<<?=, rest :: bits>>, <<"bytes">>), 
    do: range_bytes_value(rest, [], << >>)
  def range(<<?=, rest :: bits>>, key), 
    do: range_value(rest, key, << >>)
  def range(<<char, rest :: bits>>, key), 
    do: range(rest, <<key :: binary, char>>)
  
  def range_value(<< >>, key, value), do: {key, value}
  def range_value(<<char, rest :: bits>>, key, value),
    do: range_value(rest, key, <<value :: binary, char>>)
  
  def range_bytes_value(<< >>, acc, << >>), 
    do: {:bytes, Enum.reverse(acc)}
  def range_bytes_value(<< >>, acc, val),
    do: range_bytes_value(<< >>, [String.to_integer(val)|acc], << >>)
  def range_bytes_value(<<45, rest :: bits>>, acc, << >>), 
    do: range_bytes_value(rest, acc, <<45>>)
  def range_bytes_value(<<45, rest :: bits>>, acc, val), 
    do: range_bytes_value(rest, [String.to_integer(val)|acc], << >>)
  def range_bytes_value(<<?,, rest :: bits>>, acc, << >>), 
    do: range_bytes_value(rest, acc, << >>)
  def range_bytes_value(<<?,, rest :: bits>>, acc, val), 
    do: range_bytes_value(rest, [String.to_integer(val)|acc], << >>)
  def range_bytes_value(<<char, rest :: bits>>, acc, val), 
    do: range_bytes_value(rest, acc, << val :: binary, char >>)
  
  
  def etag(<< >>, acc, _, _), do: acc
  def etag(<<87, 47, 34, rest :: bits>>, acc, _, << >>), 
    do: etag(rest, acc, :weak, << >>)
  def etag(<<?", rest :: bits>>, acc, _, << >>), 
    do: etag(rest, acc, :strong, << >>)
  def etag(<<?", rest :: bits>>, acc, strength, tag), 
    do: etag(rest, [{strength, tag}|acc], nil, << >>)
  def etag(<<?\s, rest :: bits>>, acc, strength, tag), 
    do: etag(rest, acc, strength, tag)
  def etag(<<?\t, rest :: bits>>, acc, strength, tag), 
    do: etag(rest, acc, strength, tag)
  def etag(<<?,, rest :: bits>>, acc, strength, tag), 
    do: etag(rest, acc, strength, tag)
  def etag(<<char, rest :: bits>>, acc, strength, tag), 
    do: etag(rest, acc, strength, <<tag :: binary, char>>)
  
  
  def quoted_value(<<?", rest :: bits>>, acc), 
    do: {rest, acc}
  def quoted_value(<<char, rest :: bits>>, acc), 
    do: quoted_value(rest, <<acc :: binary, char>>)
  
  
  def quality_opt([], q, acc), do: {q, acc}
  def quality_opt([{<< "q" >>, val}|opts], q, acc), 
    do: quality_opt(opts, quality_value(val), acc)
  def quality_opt([opt|opts], q, acc), 
    do: quality_opt(opts, q, [opt|acc])
  
  def quality_value(val), do: val

  # Helpers

  for letter <- [?A, ?B, ?C, ?D, ?E, ?F, ?G, ?H, ?I, ?J, ?K, ?L, ?M, 
                 ?N, ?O, ?P, ?Q, ?R, ?S, ?T, ?U, ?V, ?W, ?X, ?Y, ?Z] do
    def has_uppercase?(<< unquote(letter), _ :: bits >>),
      do: true
  end

  def has_uppercase?(<< _, rest :: bits >>),  do: has_uppercase?(rest)
  def has_uppercase?(<< >>),                  do: false
end
