defmodule Surface do
  @moduledoc """
  Surface is component based library for **Phoenix LiveView**.

  Built on top of the new `Phoenix.LiveComponent` API, Surface provides
  a more declarative way to express and use components in Phoenix.

  Full documentation and live examples can be found at [surface-demo.msaraiva.io](http://surface-demo.msaraiva.io)

  This module defines the `~H` sigil that should be used to translate Surface
  code into Phoenix templates.

  In order to have `~H` available for any Phoenix view, add the following import to your web
  file in `lib/my_app_web.ex`:

      # lib/my_app_web.ex

      ...

      def view do
        quote do
          ...
          import Surface
        end
      end

  Additionally, use `Surface.init/1` in your mount function to initialize assigns used internally by surface:

      # A LiveView using surface templates

      defmodule PageLive do
        use Phoenix.LiveView
        import Surface

        def mount(socket) do
          socket = Surface.init(socket)
          ...
          {:ok, socket}
        end

        def render(assigns) do
          ~H"\""
          ...
          "\""
        end
      end

      # A LiveComponent using surface templates

      defmodule NavComponent do
        use Phoenix.LiveComponent
        import Surface

        def mount(socket) do
          socket = Surface.init(socket)
          ...
          {:ok, socket}
        end

        def render(assigns) do
          ~H"\""
          ...
          "\""
        end
      end

  ## Defining components

  To create a component you need to define a module and `use` one of the available component types:

    * `Surface.Component` - A stateless component.
    * `Surface.LiveComponent` - A live stateful component.
    * `Surface.LiveView` - A wrapper component around `Phoenix.LiveView`.
    * `Surface.MacroComponent` - A low-level component which is responsible for translating its own content at compile time.

  ### Example

      # A functional stateless component

      defmodule Button do
        use Surface.Component

        prop click, :event
        prop kind, :string, default: "is-info"

        def render(assigns) do
          ~H"\""
          <button class="button {{ @kind }}" phx-click={{ @click }}>
            <slot/>
          </button>
          "\""
        end
      end

  You can visit the documentation of each type of component for further explanation and examples.
  """

  alias Phoenix.LiveView
  alias Surface.API
  alias Surface.IOHelper
  alias Surface.Compiler.Helpers

  @doc """
  Translates Surface code into Phoenix templates.
  """
  defmacro sigil_H({:<<>>, _, [string]}, opts) do
    # This will create accurate line numbers for heredoc usages of the sigil, but
    # not for ~H* variants. See https://github.com/msaraiva/surface/issues/15#issuecomment-667305899
    line_offset = __CALLER__.line + 1

    caller_is_surface_component =
      Module.open?(__CALLER__.module) &&
        Module.get_attribute(__CALLER__.module, :component_type) != nil

    string
    |> Surface.Compiler.compile(line_offset, __CALLER__, __CALLER__.file,
      checks: [no_undefined_assigns: caller_is_surface_component]
    )
    |> Surface.Compiler.to_live_struct(
      debug: Enum.member?(opts, ?d),
      file: __CALLER__.file,
      line: __CALLER__.line
    )
  end

  @doc "Retrieve a component's config based on the `key`"
  def get_config(component, key) do
    config = get_components_config()
    config[component][key]
  end

  @doc "Retrieve the component's config based on the `key`"
  defmacro get_config(key) do
    component = __CALLER__.module

    quote do
      get_config(unquote(component), unquote(key))
    end
  end

  @doc "Retrieve all component's config"
  def get_components_config() do
    Application.get_env(:surface, :components, [])
  end

  @doc "Initialize surface state in the socket"
  def init(socket) do
    socket
    |> LiveView.assign_new(:__surface__, fn -> %{} end)
    |> LiveView.assign_new(:__context__, fn -> %{} end)
  end

  @doc false
  def default_props(module) do
    Enum.map(module.__props__(), fn %{name: name, opts: opts} -> {name, opts[:default]} end)
  end

  @doc false
  def build_assigns(
        context,
        static_props,
        dynamic_props,
        slot_props,
        slots,
        module,
        node_alias
      ) do
    static_prop_names = Keyword.keys(static_props)

    dynamic_props =
      (dynamic_props || [])
      |> Enum.filter(fn {name, _} -> not Enum.member?(static_prop_names, name) end)
      |> Enum.map(fn {name, value} ->
        {name, Surface.TypeHandler.runtime_prop_value!(module, name, value, node_alias || module)}
      end)

    props =
      module
      |> default_props()
      |> Keyword.merge(dynamic_props)
      |> Keyword.merge(static_props)
      |> rename_id_if_stateless(module.component_type())

    renamed_slot_props =
      module
      |> mapping_to_rename_slots_with_as_option()
      |> rename_slots_props(slot_props)

    Map.new(
      props ++
        renamed_slot_props ++
        [
          __surface__: %{
            slots: Map.new(slots),
            provided_templates: Keyword.keys(slot_props)
          },
          __context__: context
        ]
    )
  end

  defp mapping_to_rename_slots_with_as_option(module) do
    module.__slots__()
    |> Enum.map(fn %{name: name, opts: opts} -> {name, Keyword.get(opts, :as)} end)
    |> Enum.filter(fn value -> not match?({_, nil}, value) end)
  end

  defp rename_slots_props(mapping, slot_props) do
    slot_props
    |> Enum.map(fn {name, info} -> {Keyword.get(mapping, name, name), info} end)
  end

  @doc false
  def css_class(value) when is_list(value) do
    with {:ok, value} <- Surface.TypeHandler.CssClass.expr_to_value(value, []),
         {:ok, string} <- Surface.TypeHandler.CssClass.value_to_html("class", value) do
      string
    else
      _ ->
        Surface.IOHelper.runtime_error(
          "invalid value. " <>
            "Expected a :css_class, got: #{inspect(value)}"
        )
    end
  end

  @doc false
  def event_to_opts(%{name: name, target: :live_view}, event_name) do
    [{event_name, name}]
  end

  def event_to_opts(%{name: name, target: target}, event_name) do
    [{event_name, name}, {:phx_target, target}]
  end

  def event_to_opts(nil, _event_name) do
    []
  end

  @doc false
  defmacro prop_to_opts(prop_value, prop_name) do
    quote do
      prop_to_opts(unquote(prop_value), unquote(prop_name), __ENV__)
    end
  end

  @doc false
  def prop_to_opts(nil, _prop_name, _caller) do
    []
  end

  def prop_to_opts(prop_value, prop_name, caller) do
    module = caller.module
    meta = %{caller: caller, line: caller.line, node_alias: module}
    {type, _opts} = Surface.TypeHandler.attribute_type_and_opts(module, prop_name, meta)
    Surface.TypeHandler.attr_to_opts!(type, prop_name, prop_value)
  end

  @doc """
  Tests if a slot has been filled in.

  Useful to avoid rendering unecessary html tags that are used to wrap an optional slot
  in combination with `:if` directive.

  ## Examples

    ```
    <div :if={{ slot_assigned?(:header) }}>
      <slot name="header"/>
    </div>
    ```
  """
  defmacro slot_assigned?(slot) do
    defined_slots =
      API.get_slots(__CALLER__.module)
      |> Enum.map(& &1.name)
      |> Enum.uniq()

    if slot not in defined_slots do
      undefined_slot(defined_slots, slot, __CALLER__)
    end

    quote do
      unquote(__MODULE__).slot_assigned?(var!(assigns), unquote(slot))
    end
  end

  @doc false
  def slot_assigned?(%{__surface__: %{provided_templates: slots}}, slot), do: slot in slots
  def slot_assigned?(_, _), do: false

  defp undefined_slot(defined_slots, slot_name, caller) do
    similar_slot_message =
      case Helpers.did_you_mean(slot_name, defined_slots) do
        {similar, score} when score > 0.8 ->
          "\n\n  Did you mean #{inspect(to_string(similar))}?"

        _ ->
          ""
      end

    existing_slots_message =
      if defined_slots == [] do
        ""
      else
        slots =
          defined_slots
          |> Enum.map(&to_string/1)
          |> Enum.sort()

        available = Helpers.list_to_string("slot:", "slots:", slots)
        "\n\n  Available #{available}"
      end

    message = """
    no slot "#{slot_name}" defined in the component '#{caller.module}'\
    #{similar_slot_message}\
    #{existing_slots_message}\
    """

    IOHelper.warn(message, caller, & &1)
  end

  defp rename_id_if_stateless(props, Surface.Component) do
    case Keyword.pop(props, :id) do
      {nil, rest} -> rest
      {id, rest} -> Keyword.put(rest, :__id__, id)
    end
  end

  defp rename_id_if_stateless(props, _type) do
    props
  end
end
