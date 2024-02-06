defmodule ReqGitHubPaginate do
  @doc """
  Parses GitHub's REST Response [Link Headers](https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api?apiVersion=2022-11-28#using-link-headers)
  Inspired by [parse-link-header](https://github.com/thlorenz/parse-link-header) JS library

   ## Request Options

    * `:pagination_transform` - A transform to apply to the pagination link results. Use this if you want to
        format the pagination results differently from the defaults. The function should accept a link entry
        as input and output a transformed link entry. Defaults to `fn link -> link end`
    * `:keep_original_link` - Whether to keep the original `link` header. If `true`, the parsed links will be assigned
      to a new `"parsed_link"` key, otherwise they will override the original `"link"` key. Defaults to `false`.
  """
  @rels [:next, :prev, :first, :last]

  def attach(%Req.Request{} = request, options \\ []) do
    request
    |> Req.Request.register_options([:pagination_filter, :keep_original_link])
    |> Req.Request.merge_options(options)
    |> Req.Request.append_response_steps(parse_link_headers: &parse_link_headers/1)
  end

  def parse_link_headers(
        {request, %Req.Response{headers: %{"link" => [links_string]} = headers} = response},
        opts \\ []
      )
      when is_binary(links_string) do
    keep_original_link = Keyword.get(opts, :keep_original_link, false)
    pagination_transform = Keyword.get(opts, :pagination_transform, fn link -> link end)

    unless is_boolean(keep_original_link),
      do:
        raise(
          ArgumentError,
          "Argument `:keep_original_link` must be a boolean, got #{inspect(keep_original_link)}"
        )

    unless is_function(pagination_transform, 1),
      do:
        raise(
          ArgumentError,
          "Argument `:pagination_transform` must be an arity-1 function, got #{inspect(pagination_transform)}"
        )

    # Split the input string into segments, each containing a URL and its key-value pairs
    segments = String.split(links_string, ~r/, (?=<)/)

    # Define a regex to capture a URL and its key-value pairs
    url_regex = ~r/<([^>]+)>/
    kv_pair_regex = ~r/;\s*([^=]+)="([^"]+)"/

    # Process each segment to extract URLs and their key-value pairs
    links =
      Enum.map(segments, fn segment ->
        # Extract the URL
        [url] = Regex.scan(url_regex, segment) |> List.flatten() |> tl()

        # Extract key-value pairs
        kv_pairs = Regex.scan(kv_pair_regex, segment)

        # Convert the list of key-value pairs into a map
        kv_map =
          Enum.reduce(kv_pairs, %{}, fn [_, key, value], acc ->
            Map.put(acc, key, value)
          end)

        {rel, kv_map} = Map.pop!(kv_map, "rel")

        query_params =
          url
          |> URI.parse()
          |> Map.get(:query)
          |> then(&unless(is_nil(&1), do: URI.decode_query(&1), else: %{}))

        entry =
          kv_map
          |> Map.put_new("url", url)
          |> Map.merge(query_params)

        pagination_transform.({rel |> String.to_existing_atom(), entry})
      end)

    headers =
      if keep_original_link do
        Map.put_new(headers, "parsed_link", links)
      else
        Map.put(headers, "link", links)
      end

    {request, struct!(response, headers: headers)}
  end

  def parse_link_header({request, %Req.Response{headers: %{"link" => _other}} = response}),
    do: {request, response}
end
