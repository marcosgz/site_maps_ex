defmodule SiteMaps.URL do
  @moduledoc """
  A `<url>` entry of a urlset, validated and normalized by `new/2`.

  ## Options

    * `:lastmod` - `DateTime`, `NaiveDateTime` (treated as UTC), `Date` or ISO 8601 string.
      Omitted when `nil`; it never defaults to the current time.
    * `:changefreq` - one of `always hourly daily weekly monthly yearly never` (atom or string).
    * `:priority` - a number between `0.0` and `1.0`, written with one decimal.
    * `:images` / `:image` - one image or a list (up to 1,000). Keys: `:loc` (required) and the
      deprecated `:caption`, `:title`, `:license` and `:geo_location`.
    * `:videos` / `:video` - one video or a list. Keys: `:thumbnail_loc`, `:title`, `:description`
      (required), `:content_loc` and/or `:player_loc` (one is required), `:allow_embed`, `:autoplay`
      (a string such as `"ap=1"`), `:duration`, `:expiration_date`, `:rating`, `:view_count`, `:publication_date`, `:tags`
      (a string or list of strings, up to 32), `:family_friendly`,
      `:restriction` (`%{relationship: :allow | :deny, countries: ["US", ..]}`, ISO 3166 codes in upper case),
      `:platform` (`%{relationship: :allow | :deny, platforms: [:web | :mobile | :tv]}`),
      `:requires_subscription`, `:uploader`, `:uploader_info`, `:live` and the deprecated
      `:category`, `:gallery_loc`, `:gallery_title` and `:price`
      (`%{value: .., currency: "USD", type: :rent | :purchase, resolution: :hd | :sd}`, one or a list;
      `:value` is a non-negative decimal that requires `:currency`, and without it `:type` is required).
      Booleans are three-state: `nil` leaves the element out, `true`/`false` write `yes`/`no`.
    * `:news` - `:publication_name`, `:publication_language` (ISO 639 code of 2 or 3 lower case letters,
      or `zh-cn`/`zh-tw`), `:title`, `:publication_date` (required) and the deprecated `:access`, `:genres`, `:keywords` and `:stock_tickers`.
    * `:alternates` / `:alternate` - one or a list of `%{href: .., lang: .., media: .., nofollow: bool}`,
      written as `<xhtml:link rel="alternate">`.
    * `:mobile` - deprecated, `true` writes `<mobile:mobile/>`.
    * `:pagemap` - deprecated, `%{dataobjects: [%{type: .., id: .., attributes: [%{name: .., value: ..}]}]}`.

  Invalid values raise `ArgumentError`.
  """

  @max_loc_length 2048
  @max_images 1000
  @max_video_tags 32
  @max_stock_tickers 5
  @changefreqs ~w(always hourly daily weekly monthly yearly never)a

  @url_keys ~w(lastmod changefreq priority images image videos video news alternates alternate mobile pagemap)a
  @image_keys ~w(loc caption title license geo_location)a
  @video_keys ~w(thumbnail_loc title description content_loc player_loc allow_embed autoplay duration
                 expiration_date rating view_count publication_date tags tag category family_friendly
                 restriction platform gallery_loc gallery_title price requires_subscription uploader
                 uploader_info live)a
  @news_keys ~w(publication_name publication_language title publication_date access genres keywords
                stock_tickers)a
  @alternate_keys ~w(href lang hreflang media nofollow)a
  @video_booleans ~w(allow_embed family_friendly requires_subscription live)a
  @platforms ~w(web mobile tv)
  @price_types ~w(rent purchase)
  @price_resolutions ~w(hd sd)
  @news_access ~w(Subscription Registration)
  @news_genres ~w(PressRelease Satire Blog OpEd Opinion UserGenerated)
  @image_url_keys ~w(loc license)a
  @video_url_keys ~w(thumbnail_loc content_loc player_loc gallery_loc uploader_info)a

  @enforce_keys [:loc]
  defstruct [
    :loc,
    :lastmod,
    :changefreq,
    :priority,
    :news,
    :pagemap,
    images: [],
    videos: [],
    alternates: [],
    mobile: false
  ]

  @type changefreq :: :always | :hourly | :daily | :weekly | :monthly | :yearly | :never
  @type t :: %__MODULE__{
          loc: String.t(),
          lastmod: DateTime.t() | Date.t() | nil,
          changefreq: changefreq | nil,
          priority: float | nil,
          images: [map],
          videos: [map],
          news: map | nil,
          alternates: [map],
          mobile: boolean,
          pagemap: map | nil
        }

  @doc "Builds a validated URL entry. See the module documentation for the options."
  @spec new(String.t(), keyword | map) :: t
  def new(loc, opts \\ []) do
    opts = to_map(opts, @url_keys, "url")

    %__MODULE__{
      loc: loc!(loc),
      lastmod: SiteMaps.Date.cast!(opts[:lastmod], :lastmod),
      changefreq: changefreq!(opts[:changefreq]),
      priority: priority!(opts[:priority]),
      images: images!(many(opts[:images]) ++ many(opts[:image])),
      videos: Enum.map(many(opts[:videos]) ++ many(opts[:video]), &video!/1),
      news: news!(opts[:news]),
      alternates: Enum.map(many(opts[:alternates]) ++ many(opts[:alternate]), &alternate!/1),
      mobile: mobile!(opts[:mobile]),
      pagemap: pagemap!(opts[:pagemap])
    }
  end

  @doc "Whether the entry carries `<news:news>`."
  @spec news?(t) :: boolean
  def news?(%__MODULE__{news: news}), do: news != nil

  @doc """
  Applies `fun` to every URL-valued nested field: image `:loc` and `:license`, video `:thumbnail_loc`,
  `:content_loc`, `:player_loc`, `:gallery_loc` and `:uploader_info`, and alternate `:href`.
  The entry `loc` itself is left untouched.
  """
  @spec map_locs(t, (String.t() -> String.t())) :: t
  def map_locs(%__MODULE__{} = url, fun) when is_function(fun, 1) do
    %{
      url
      | images: Enum.map(url.images, &map_keys(&1, @image_url_keys, fun)),
        videos: Enum.map(url.videos, &map_keys(&1, @video_url_keys, fun)),
        alternates: Enum.map(url.alternates, &map_keys(&1, [:href], fun))
    }
  end

  @doc false
  @spec max_loc_length() :: pos_integer
  def max_loc_length, do: @max_loc_length

  @doc false
  @spec loc_length(String.t()) :: non_neg_integer
  def loc_length(value) when is_binary(value), do: length(String.to_charlist(value))

  defp map_keys(map, keys, fun) do
    Enum.reduce(keys, map, fn key, acc ->
      case acc do
        %{^key => value} when is_binary(value) -> %{acc | key => fun.(value)}
        _ -> acc
      end
    end)
  end

  defp loc!(loc) when is_binary(loc) and loc != "" do
    if loc_length(loc) >= @max_loc_length do
      raise ArgumentError, "loc must have less than #{@max_loc_length} characters, got #{loc_length(loc)}"
    end

    loc
  end

  defp loc!(loc), do: raise(ArgumentError, "loc must be a non-empty string, got: #{inspect(loc)}")

  defp changefreq!(nil), do: nil
  defp changefreq!(value) when value in @changefreqs, do: value

  defp changefreq!(value) when is_binary(value) do
    case Enum.find(@changefreqs, &(Atom.to_string(&1) == value)) do
      nil -> invalid_changefreq!(value)
      changefreq -> changefreq
    end
  end

  defp changefreq!(value), do: invalid_changefreq!(value)

  defp invalid_changefreq!(value) do
    raise ArgumentError, "changefreq must be one of #{inspect(@changefreqs)}, got: #{inspect(value)}"
  end

  defp priority!(nil), do: nil
  defp priority!(value) when is_number(value) and value >= 0 and value <= 1, do: value / 1

  defp priority!(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> priority!(float)
      _ -> invalid_priority!(value)
    end
  end

  defp priority!(value), do: invalid_priority!(value)

  defp invalid_priority!(value) do
    raise ArgumentError, "priority must be a number between 0.0 and 1.0, got: #{inspect(value)}"
  end

  defp images!(images) when length(images) > @max_images do
    raise ArgumentError, "a url can have at most #{@max_images} images, got #{length(images)}"
  end

  defp images!(images) do
    Enum.map(images, fn image ->
      image = to_map(image, @image_keys, "image")
      required!(image, [:loc], "image")
      image
    end)
  end

  defp video!(video) do
    video = to_map(video, @video_keys, "video")
    required!(video, [:thumbnail_loc, :title, :description], "video")

    unless video[:content_loc] || video[:player_loc] do
      raise ArgumentError, "video requires :content_loc or :player_loc, got: #{inspect(video)}"
    end

    max_length!(video, :title, 100)
    max_length!(video, :description, 2048)
    max_length!(video, :category, 256)

    video
    |> Map.merge(Map.new(@video_booleans, &{&1, yes_no!(video[&1], &1)}))
    |> Map.put(:autoplay, autoplay!(video[:autoplay]))
    |> Map.put(:tags, video_tags!(video))
    |> Map.delete(:tag)
    |> Map.put(:expiration_date, SiteMaps.Date.cast!(video[:expiration_date], :expiration_date))
    |> Map.put(:publication_date, SiteMaps.Date.cast!(video[:publication_date], :publication_date))
    |> Map.put(:duration, bounded_integer!(video[:duration], :duration, 0..28_800))
    |> Map.put(:view_count, bounded_integer!(video[:view_count], :view_count, 0..999_999_999_999))
    |> Map.put(:rating, rating!(video[:rating]))
    |> Map.put(:restriction, relationship!(video[:restriction], :restriction, :countries))
    |> Map.put(:platform, relationship!(video[:platform], :platform, :platforms))
    |> Map.put(:price, Enum.map(many(video[:price]), &price!/1))
    |> reject_nil()
  end

  defp video_tags!(video) do
    tags = tag_values(video[:tags]) ++ tag_values(video[:tag])

    if length(tags) > @max_video_tags do
      raise ArgumentError, "a video can have at most #{@max_video_tags} tags, got #{length(tags)}"
    end

    Enum.map(tags, &to_string/1)
  end

  defp tag_values(nil), do: []
  defp tag_values(list) when is_list(list), do: list
  defp tag_values(value), do: [value]

  defp autoplay!(nil), do: nil
  defp autoplay!(value) when is_binary(value), do: value
  defp autoplay!(value), do: raise(ArgumentError, "autoplay must be a string such as \"ap=1\", got: #{inspect(value)}")

  defp yes_no!(nil, _field), do: nil
  defp yes_no!(value, _field) when is_boolean(value), do: value

  defp yes_no!(value, field) when is_binary(value) do
    case String.downcase(value) do
      "yes" -> true
      "no" -> false
      _ -> raise ArgumentError, "#{field} must be a boolean or \"yes\"/\"no\", got: #{inspect(value)}"
    end
  end

  defp yes_no!(value, field), do: raise(ArgumentError, "#{field} must be a boolean, got: #{inspect(value)}")

  defp bounded_integer!(nil, _field, _range), do: nil

  defp bounded_integer!(value, field, range) do
    if is_integer(value) and value in range do
      value
    else
      raise ArgumentError, "#{field} must be an integer in #{inspect(range)}, got: #{inspect(value)}"
    end
  end

  defp rating!(nil), do: nil
  defp rating!(value) when is_number(value) and value >= 0 and value <= 5, do: value / 1
  defp rating!(value), do: raise(ArgumentError, "rating must be a number between 0 and 5, got: #{inspect(value)}")

  defp relationship!(nil, _field, _list_key), do: nil

  defp relationship!(value, field, list_key) do
    value = to_map(value, [:relationship, list_key], to_string(field))
    required!(value, [:relationship], to_string(field))

    relationship =
      case to_string(value.relationship) do
        rel when rel in ["allow", "deny"] -> rel
        other -> raise ArgumentError, "#{field} relationship must be :allow or :deny, got: #{inspect(other)}"
      end

    values = value |> Map.get(list_key) |> many_values() |> Enum.map(&to_string/1)
    Enum.each(values, &relationship_value!(field, &1))

    %{relationship: relationship, values: values}
  end

  defp relationship_value!(:restriction, country) do
    unless country =~ ~r/\A[A-Z]{2}\z/ do
      raise ArgumentError, "restriction countries must be ISO 3166 codes in upper case, got: #{inspect(country)}"
    end
  end

  defp relationship_value!(:platform, platform) do
    unless platform in @platforms do
      raise ArgumentError, "platform platforms must be in #{inspect(@platforms)}, got: #{inspect(platform)}"
    end
  end

  defp price!(price) do
    price = to_map(price, [:value, :currency, :type, :resolution], "price")

    if price[:value] in [nil, ""] do
      required!(price, [:type], "price without value")
    else
      price_value!(price.value)
      required!(price, [:currency], "price")
    end

    if price[:currency] && !(is_binary(price.currency) and price.currency =~ ~r/\A[A-Z]{3}\z/) do
      raise ArgumentError, "price currency must be an ISO 4217 code in upper case, got: #{inspect(price.currency)}"
    end

    price
    |> Map.put(:value, if(price[:value] != "", do: price[:value]))
    |> Map.put(:type, enum!(price[:type], @price_types, "price type"))
    |> Map.put(:resolution, enum!(price[:resolution], @price_resolutions, "price resolution"))
    |> reject_nil()
  end

  defp price_value!(value) when is_number(value) and value >= 0, do: :ok

  defp price_value!(value) when is_binary(value) do
    unless value =~ ~r/\A\+?(\d+(\.\d*)?|\.\d+)\z/, do: invalid_price_value!(value)
  end

  defp price_value!(value), do: invalid_price_value!(value)

  defp invalid_price_value!(value) do
    raise ArgumentError, "price value must be a non-negative decimal, got: #{inspect(value)}"
  end

  defp enum!(nil, _allowed, _name), do: nil

  defp enum!(value, allowed, name) when is_atom(value) or is_binary(value) do
    string = value |> to_string() |> String.downcase()
    if string in allowed, do: string, else: invalid_enum!(value, allowed, name)
  end

  defp enum!(value, allowed, name), do: invalid_enum!(value, allowed, name)

  defp invalid_enum!(value, allowed, name) do
    raise ArgumentError, "#{name} must be one of #{inspect(allowed)}, got: #{inspect(value)}"
  end

  defp news!(nil), do: nil

  defp news!(news) do
    news = to_map(news, @news_keys, "news")
    required!(news, [:publication_name, :publication_language, :title, :publication_date], "news")
    language!(news.publication_language)

    news
    |> Map.put(:publication_date, SiteMaps.Date.cast!(news.publication_date, :publication_date))
    |> Map.put(:access, news_access!(news[:access]))
    |> Map.put(:genres, news_genres!(news[:genres]))
    |> Map.update(:keywords, nil, &join/1)
    |> Map.put(:stock_tickers, stock_tickers!(news[:stock_tickers]))
    |> reject_nil()
  end

  defp news_access!(nil), do: nil
  defp news_access!(access) when access in @news_access, do: access

  defp news_access!(access) do
    raise ArgumentError, "news access must be one of #{inspect(@news_access)}, got: #{inspect(access)}"
  end

  defp news_genres!(genres) do
    genres = split_list(genres)

    case Enum.reject(genres, &(&1 in @news_genres)) do
      [] -> join_present(genres)
      invalid -> raise ArgumentError, "news genres must be in #{inspect(@news_genres)}, got: #{inspect(invalid)}"
    end
  end

  defp stock_tickers!(tickers) do
    tickers = split_list(tickers)

    if length(tickers) > @max_stock_tickers do
      raise ArgumentError, "news can have at most #{@max_stock_tickers} stock_tickers, got #{length(tickers)}"
    end

    case Enum.reject(tickers, &(&1 =~ ~r/\A\w+:\w+\z/)) do
      [] -> join_present(tickers)
      invalid -> raise ArgumentError, "news stock_tickers must look like \"NASDAQ:AMAT\", got: #{inspect(invalid)}"
    end
  end

  defp split_list(nil), do: []
  defp split_list(value) when is_binary(value), do: split_list(String.split(value, ","))

  defp split_list(list) when is_list(list),
    do: list |> Enum.map(&(&1 |> to_string() |> String.trim())) |> Enum.reject(&(&1 == ""))

  defp split_list(value), do: split_list([value])

  defp join_present([]), do: nil
  defp join_present(list), do: Enum.join(list, ", ")

  defp language!(language) when language in ["zh-cn", "zh-tw"], do: :ok

  defp language!(language) do
    unless is_binary(language) and language =~ ~r/\A[a-z]{2,3}\z/ do
      raise ArgumentError,
            "news publication_language must be an ISO 639 code of 2 or 3 lower case letters, or zh-cn/zh-tw, " <>
              "got: #{inspect(language)}"
    end
  end

  defp alternate!(alternate) do
    alternate = to_map(alternate, @alternate_keys, "alternate")
    required!(alternate, [:href], "alternate")

    alternate
    |> Map.put(:lang, alternate[:lang] || alternate[:hreflang])
    |> Map.delete(:hreflang)
    |> Map.put(:nofollow, alternate[:nofollow] == true)
    |> reject_nil()
  end

  defp mobile!(nil), do: false
  defp mobile!(value) when is_boolean(value), do: value
  defp mobile!(value), do: raise(ArgumentError, "mobile must be a boolean, got: #{inspect(value)}")

  defp pagemap!(nil), do: nil

  defp pagemap!(pagemap) do
    pagemap = to_map(pagemap, [:dataobjects], "pagemap")

    dataobjects =
      Enum.map(many(pagemap[:dataobjects]), fn dataobject ->
        dataobject = to_map(dataobject, [:type, :id, :attributes], "pagemap dataobject")
        required!(dataobject, [:type], "pagemap dataobject")

        attributes =
          Enum.map(many(dataobject[:attributes]), fn attribute ->
            attribute = to_map(attribute, [:name, :value], "pagemap attribute")
            required!(attribute, [:name], "pagemap attribute")
            attribute
          end)

        dataobject |> Map.put(:attributes, attributes) |> reject_nil()
      end)

    %{dataobjects: dataobjects}
  end

  defp many(nil), do: []
  defp many([]), do: []
  defp many(%{} = map), do: [map]

  defp many(list) when is_list(list) do
    if Keyword.keyword?(list), do: [list], else: list
  end

  defp many(other), do: raise(ArgumentError, "expected a map, keyword list or a list of them, got: #{inspect(other)}")

  defp many_values(nil), do: []
  defp many_values(list) when is_list(list), do: list
  defp many_values(value) when is_binary(value), do: String.split(value)
  defp many_values(value), do: [value]

  defp join(nil), do: nil
  defp join(list) when is_list(list), do: Enum.map_join(list, ", ", &to_string/1)
  defp join(value), do: to_string(value)

  defp to_map(value, allowed, name) when is_list(value) or is_map(value) do
    map = Map.new(value)

    case Map.keys(map) -- allowed do
      [] -> map
      unknown -> raise ArgumentError, "unknown #{name} options #{inspect(unknown)}, allowed: #{inspect(allowed)}"
    end
  end

  defp to_map(value, _allowed, name) do
    raise ArgumentError, "expected #{name} to be a map or keyword list, got: #{inspect(value)}"
  end

  defp required!(map, keys, name) do
    case Enum.filter(keys, &(map[&1] in [nil, ""])) do
      [] -> :ok
      missing -> raise ArgumentError, "#{name} requires #{inspect(missing)}, got: #{inspect(map)}"
    end
  end

  defp max_length!(map, key, max) do
    if map[key] && loc_length(to_string(map[key])) > max do
      raise ArgumentError, "video #{key} must have at most #{max} characters"
    end
  end

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
