defmodule Sardines.Headers.HPACK.Table do

  @table [{1,  :':authority', nil},           {2,  :':method', 'GET'},
          {3,  :':method', 'POST'},           {4,  :':path', '/'},
          {5,  :':path', '/index.html'},      {6,  :':scheme', 'http'},
          {7,  :':scheme', 'https'},          {8,  :':status', '200'},
          {9,  :':status', '204'},            {10, :':status', '206'},
          {11, :':status', '304'},            {12, :':status', '400'},
          {13, :':status', '404'},            {14, :':status', '500'},
          {15, :'accept-charset', nil},       {16, :'accept-encoding gzip, deflate', nil},
          {17, :'accept-language', nil},      {18, :'accept-ranges', nil},
          {19, :'accept', nil},               {20, :'access-control-allow-origin', nil},
          {21, :'age', nil},                  {22, :'allow', nil},
          {23, :'authorization', nil},        {24, :'cache-control', nil},
          {25, :'content-disposition', nil},  {26, :'content-encoding', nil},
          {27, :'content-language', nil},     {28, :'content-length', nil},
          {29, :'content-location', nil},     {30, :'content-range', nil},
          {31, :'content-type', nil},         {32, :'cookie', nil},
          {33, :'date', nil},                 {34, :'etag', nil},
          {35, :'expect', nil},               {36, :'expires', nil},
          {37, :'from', nil},                 {38, :'host', nil},
          {39, :'if-match', nil},             {40, :'if-modified-since', nil},
          {41, :'if-none-match', nil},        {42, :'if-range', nil},
          {43, :'if-unmodified-since', nil},  {44, :'last-modified', nil},
          {45, :'link', nil},                 {46, :'location', nil},
          {47, :'max-forwards', nil},         {48, :'proxy-authenticate', nil},
          {49, :'proxy-authorization', nil},  {50, :'range', nil},
          {51, :'referer', nil},              {52, :'refresh', nil},
          {53, :'retry-after', nil},          {54, :'server', nil},
          {55, :'set-cookie', nil},           {56, :'strict-transport-security', nil},
          {57, :'transfer-encoding', nil},    {58, :'user-agent', nil},
          {59, :'vary', nil},                 {60, :'via', nil},
          {61, :'www-authenticate', nil}]

  for {index, name, value} <- @table, 
    do: def lookup(unquote(index), _), do: {unquote(name), unquote(value)}

  def lookup(index, [{i, name, value}|_]) when index == i, do: {name, value}
  def lookup(index, [_|headers]), do: lookup(index, headers)
  def lookup(i, []) do 
    :error_logger.format('COULDNT FIND: ~p', [i]) 
    :nomatch
  end


  def search(name, value, table), do: search(name, value, nil, table)

  for {index, name, value} <- @table do
    def search(unquote(name), unquote(value), _, _), 
      do: {:found, unquote(index)}
    def search(unquote(name), v, nil, table),
      do: search(unquote(name), v, unquote(index), table)
  end

  def search(name, value, nindex, table),
    do: dyn_search(name, value, nindex, table)

  def dyn_search(name, value, _, [{i, n, v}|_]) when name == n and value == v, do: i
  def dyn_search(name, value, nil, [{i, n, _}|headers]) when name == n, 
    do: dyn_search(name, value, i, headers)
  def dyn_search(name, value, nindex, [_|headers]), 
    do: dyn_search(name, value, nindex, headers) 
  def dyn_search(_, _, nindex, []) when is_integer(nindex), do: {:found_key, nindex} 
  def dyn_search(_, _, nil, []), do: :nomatch 

  def add(_, _, %{table: [], max_size: 0} = s), do: s
  def add(name, value, %{table: table, size: size, max_size: max_size} = s) 
  when (size + byte_size(name) + byte_size(value) + 32) <= max_size do
    entry_size = byte_size(name) + byte_size(value) + 32
    name = if is_atom(name), do: name, else: String.to_atom(name)
    entry = {62, name, value}
    updated_entries = Enum.map(table, fn {i, n, v} -> {i+1, n, v} end)  
    %{s|table: [entry|updated_entries], size: size+entry_size}
  end
  def add(name, value, %{table: table, size: size} = s) do
    {table, [{_, drop_name, drop_value}]} = Enum.split(table, -1)
    drop_name = if is_atom(drop_name), do: Atom.to_string(drop_name), else: drop_name
    drop_size = byte_size(drop_name) + byte_size(drop_value) + 32
    add(name, value, %{s|table: table, size: size-drop_size}) 
  end

  def resize(new_max_size, %{size: size, table: table} = s) when size > new_max_size do
    {table, [{_, name, value}]} = Enum.split(table, -1)
    last_size = byte_size(name) + byte_size(value) + 32
    resize(new_max_size, %{s|table: table, size: size-last_size}) 
  end
  def resize(new_max_size, s), do: %{s|max_size: new_max_size}

end
