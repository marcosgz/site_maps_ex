defmodule SiteMaps.XMLHelpers do
  @moduledoc "XPath queries with the sitemap namespaces and `xmllint` schema validation for tests."

  import SweetXml, only: [sigil_x: 2]

  @namespaces [
    {"sm", "http://www.sitemaps.org/schemas/sitemap/0.9"},
    {"xhtml", "http://www.w3.org/1999/xhtml"},
    {"image", "http://www.google.com/schemas/sitemap-image/1.1"},
    {"video", "http://www.google.com/schemas/sitemap-video/1.1"},
    {"news", "http://www.google.com/schemas/sitemap-news/0.9"},
    {"mobile", "http://www.google.com/schemas/sitemap-mobile/1.0"},
    {"pagemap", "http://www.google.com/schemas/sitemap-pagemap/1.0"}
  ]

  @xsd_dir Path.expand("../fixtures/xsd", __DIR__)

  @doc "Parses XML (iodata) with namespace support."
  def parse(xml), do: xml |> IO.iodata_to_binary() |> SweetXml.parse(namespace_conformant: true, quiet: true)

  @doc "Text of the first node matching `path`, or `nil`. Prefixes: sm, xhtml, image, video, news, mobile, pagemap."
  def xpath(doc, path), do: query(doc, path, ~c"s") |> blank_to_nil()

  @doc "Texts of every node matching `path`."
  def xpath_all(doc, path), do: query(doc, path, ~c"sl")

  @doc "Number of nodes matching `path`."
  def count(doc, path), do: doc |> query(path, ~c"l") |> length()

  @doc "Local names of the element children of the first node matching `path`, in document order."
  def child_names(doc, path) do
    doc
    |> query(path <> "/*", ~c"l")
    |> Enum.map(fn node -> node |> elem(1) |> local_name() end)
  end

  @doc "Wraps a rendered `<url>` in a urlset."
  def urlset(url_xml, config), do: [SiteMaps.XML.urlset_header(config), url_xml, SiteMaps.XML.urlset_footer()]

  @doc "Directory of the vendored schemas."
  def xsd_dir, do: @xsd_dir

  @doc "Whether `xmllint` is available."
  def xmllint?, do: System.find_executable("xmllint") != nil

  @doc "Validates `xml` with `xmllint --schema`. Returns `:ok` or `{:error, output}`."
  def validate(xml, schema) do
    path = Path.join(System.tmp_dir!(), "site_maps-xsd-#{System.unique_integer([:positive])}.xml")
    File.write!(path, xml)

    try do
      case System.cmd("xmllint", ["--noout", "--nonet", "--schema", Path.join(@xsd_dir, schema), path],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {output, _} -> {:error, output}
      end
    after
      File.rm(path)
    end
  end

  defp query(doc, path, modifiers) do
    spec =
      Enum.reduce(@namespaces, sigil_x(path, modifiers), fn {prefix, uri}, spec ->
        SweetXml.add_namespace(spec, prefix, uri)
      end)

    SweetXml.xpath(doc, spec)
  end

  defp local_name(name) do
    name |> to_string() |> String.split(":") |> List.last()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
