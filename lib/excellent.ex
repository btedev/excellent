defmodule Excellent do
  require Record

  Record.defrecord :xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  Record.defrecord :xmlAttribute, Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  Record.defrecord :xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")

  @seconds_in_day 24 * 60 * 60
  @base_date :calendar.datetime_to_gregorian_seconds({{1899, 12, 30}, {0,0,0}})

  def parse filename, num_of_worksheet do
    xml_content = file_content(filename, 'xl/worksheets/sheet#{num_of_worksheet + 1}.xml')

    {:ok, res, _} = :xmerl_sax_parser.stream(xml_content, event_fun: &event/3, event_state: %{shared_strings: shared_strings(filename), styles: styles(filename), content: []})
    res[:content]
  end

  def worksheet_names filename do
    {xml, _rest} = :xmerl_scan.string(:erlang.binary_to_list(file_content(filename, 'xl/workbook.xml')))
    :xmerl_xpath.string('/workbook/sheets/sheet/@name', xml) |> Enum.map(fn(x) -> :erlang.list_to_binary(xmlAttribute(x, :value)) end) |> List.to_tuple
  end

  def shared_strings(spreadsheet_filename) do
    shared_strings_to_tuple(file_content(spreadsheet_filename, 'xl/sharedStrings.xml'))
  end

  def shared_strings_to_tuple(shared_strings) do
    {xml, _rest} = :xmerl_scan.string(:erlang.binary_to_list(shared_strings))
    :xmerl_xpath.string('/sst/si/t', xml)
      |> Enum.map(fn(element) -> xmlElement(element, :content) end)
      |> Enum.map(fn(texts) -> Enum.map(texts, fn(text) -> to_string(xmlText(text, :value)) end) |> Enum.join end)
      |> List.to_tuple
  end

  def styles(spreadsheet_filename) do
    styles_to_tuple(file_content(spreadsheet_filename, 'xl/styles.xml'))
  end

  def styles_to_tuple(styles) do
    {xml, _rest} = :xmerl_scan.string(:erlang.binary_to_list(styles))
    lookup = :xmerl_xpath.string('/styleSheet/numFmts/numFmt', xml)
      |> Enum.map(fn(numFmt) -> { extract_attribute(numFmt, 'numFmtId'), extract_attribute(numFmt, 'formatCode') } end)
      |> Enum.into(%{})

    :xmerl_xpath.string('/styleSheet/cellXfs/xf/@numFmtId', xml)
      |> Enum.map(fn(numFmtId) -> to_string(xmlAttribute(numFmtId, :value)) end)
      |> Enum.map(fn(numFmtId) -> lookup[numFmtId] end)
      |> List.to_tuple
  end

  defp extract_attribute(node, attr_name) do
    [ret | _] = :xmerl_xpath.string('./@#{attr_name}', node)
    xmlAttribute(ret, :value) |> to_string
  end

  defp file_content(spreadsheet_filename, inner_filename) do
    {:ok, [{_filename, file_content}]} = :zip.extract spreadsheet_filename, [:memory, {:file_filter, fn(file) -> elem(file, 1) == inner_filename end }]
    file_content
  end

  defp event({:startElement, _, 'row', _, _}, _, state) do
    Dict.put(state, :current_row, [])
  end

  defp event({:startElement, _, 'c', _, [_, {_, _, 's', style}, {_, _, 't', type}]}, _, state) do
    { style_int, _ } = Integer.parse(to_string(style))
    style_content = elem(state.styles, style_int)
    type = calculate_type(style_content, to_string(type))
    Dict.put(state, :type, type)
  end

  defp event({:startElement, _, 'c', _, [_, _, {_, _, 't', 's'}]}, _, state) do
    Dict.put(state, :type, "string")
  end

  defp event({:endElement, _, 'c', _}, _, state) do
    Dict.delete(state, :type)
  end

  defp event({:startElement, _, 'v', _, _}, _, state) do
    Dict.put(state, :collect, true)
  end

  defp event({:startElement, _, 'f', _, _}, _, state) do
    Dict.put(state, :type, "boolean")
  end

  defp event({:endElement, _, 'v', _}, _, state) do
    Dict.put(state, :collect, false)
  end

  defp event({:characters, chars}, _, %{ collect: true, type: "shared_string" } = state) do
    {line, _} = chars |> :erlang.list_to_binary |> Integer.parse
    line = elem(state[:shared_strings], line)

    Dict.put(state, :current_row, List.insert_at(state[:current_row],-1, line))
  end

  defp event({:characters, chars}, _, %{ collect: true, type: "number" } = state) do
    value = case chars |> :erlang.list_to_binary |> Integer.parse do
      { int, "" } ->
        int
      { float_number, float_decimals } ->
        {float, _} = Float.parse("#{float_number}#{float_decimals}")
        float
      end
    Dict.put(state, :current_row, List.insert_at(state[:current_row],-1, value))
  end

  defp event({:characters, chars}, _, %{ collect: true, type: "boolean" } = state) do
    value = if :erlang.list_to_binary(chars) == "1" do
      true
    else
      false
    end
    Dict.put(state, :current_row, List.insert_at(state[:current_row],-1, value))
  end

  defp event({:characters, chars}, _, %{ collect: true, type: "date" } = state) do
    { ajd, _ } = :erlang.list_to_binary(chars) |> Float.parse

    datetime = @base_date + ajd * @seconds_in_day |> round |> :calendar.gregorian_seconds_to_datetime

    Dict.put(state, :current_row, List.insert_at(state[:current_row],-1, datetime))
  end

  defp event({:endElement, _, 'row', _}, _, state) do
    Dict.put(state, :content, List.insert_at(state[:content],-1, state[:current_row]))
  end

  defp event(_, _, state) do
    state
  end

  defp calculate_type(style, type) do
    stripped_style = Regex.replace(~r/(\"[^\"]*\"|\[[^\]]*\]|[\\_*].)/i, style, "")
    if Regex.match?(~r/[dmyhs]/i, stripped_style) do
      "date"
    else
      case {type, style} do
        {"s", _} ->
          "shared_string"
        {"n", _} ->
          "number"
        {"b", _} ->
          "boolean"
        _ ->
          "string"
      end
    end
  end
end
