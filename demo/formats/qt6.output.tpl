{% extends "luabridge3.tpl" %}
{#- Everything before //@@BEGIN_BODY is the header shared by all parts, every //@@CLASS line
    starts the registration of one class, tools/qt6_gen.py cuts the file there. -#}
{%- block prologue -%}
// DO NOT EDIT - Auto-generated Qt6 bindings ({{ module_name }}) by tsujikiri

#include "qt6_lua.h"
{%- for inc in includes %}
#include {{ inc }}
{%- endfor %}

//@@BEGIN_BODY
{%- endblock %}

{%- block api_version %}{% endblock %}
{%- block api_version_registration %}{% endblock %}

{#- Namespace level enums. Qt::AlignLeft is spelled qt6.Qt.AlignLeft in Lua, the values of
    a namespace level enum are also reachable through the enum (qt6.Qt.AlignmentFlag.AlignLeft) -#}
{%- block enum scoped %}
{%- if enum.namespaces %}
      .beginNamespace("{{ enum.namespaces | join('_') }}")
{%- for value in enum.values %}
        .addProperty("{{ value.name }}", +[] { return static_cast<std::underlying_type_t<{{ enum.qualified_name }}>>({{ enum.qualified_name }}::{{ value.original_name }}); })
{%- endfor %}
        .beginNamespace("{{ enum.name }}")
{%- for value in enum.values %}
          .addProperty("{{ value.name }}", +[] { return static_cast<std::underlying_type_t<{{ enum.qualified_name }}>>({{ enum.qualified_name }}::{{ value.original_name }}); })
{%- endfor %}
        .endNamespace()
      .endNamespace()
{%- else %}
      .beginNamespace("{{ enum.name }}")
{%- for value in enum.values %}
        .addProperty("{{ value.name }}", +[] { return static_cast<std::underlying_type_t<{{ enum.qualified_name }}>>({{ enum.qualified_name }}::{{ value.original_name }}); })
{%- endfor %}
      .endNamespace()
{%- endif %}
{%- endblock %}

{#- A class table cannot hold namespaces: the values of an unscoped enum are properties of the
    class (qt6.QEvent.KeyPress, as in C++), and each enum is also a table (qt6.QEvent.Type.KeyPress) -#}
{%- block class_enum scoped %}
{%- if not enum.is_scoped %}
{%- for value in enum.values %}
        .addStaticProperty("{{ value.name }}", +[] { return static_cast<lua_Integer>({{ enum.qualified_name }}::{{ value.original_name }}); })
{%- endfor %}
{%- endif %}
        .addStaticProperty("{{ enum.name }}", +[](lua_State* L) {
          auto values = luabridge::newTable(L);
{%- for value in enum.values %}
          values["{{ value.name }}"] = static_cast<lua_Integer>({{ enum.qualified_name }}::{{ value.original_name }});
{%- endfor %}
          return values;
        })
{%- endblock %}

{#- Every method comes with the exact pointer or lambda to bind (tools/qt6_gen.py): print it in
    the overload sets as well. The expansions of default arguments are lambdas of their own. -#}
{%- block class_overloaded_method scoped %}
{%- if method.wrapper_code and not method.is_default_expansion %}
          {{ method.wrapper_code }}{{ method.overload_separator }}
{%- else %}
{{ super() }}
{%- endif %}
{%- endblock %}

{%- block class_overloaded_static_method scoped %}
{%- if method.wrapper_code and not method.is_default_expansion %}
          {{ method.wrapper_code }}{{ method.overload_separator }}
{%- else %}
{{ super() }}
{%- endif %}
{%- endblock %}

{%- block class_overloaded_metamethod scoped %}
{%- if method.wrapper_code and not method.is_default_expansion %}
          {{ method.wrapper_code }}{{ method.overload_separator }}
{%- else %}
{{ super() }}
{%- endif %}
{%- endblock %}

{#- Functions of a C++ namespace are in the Lua namespace of the same name: qt6.QTest.mouse_click -#}
{%- block function_group scoped %}
{%- set function_namespaces = group.functions[0].namespaces %}
{%- if function_namespaces %}
      .beginNamespace("{{ function_namespaces | join('_') }}")
{{ super() }}
      .endNamespace()
{%- else %}
{{ super() }}
{%- endif %}
{%- endblock %}

{%- block function_overloaded scoped %}
{%- if fn.wrapper_code and not fn.is_default_expansion %}
        {{ fn.wrapper_code }}{{ fn.overload_separator }}
{%- else %}
{{ super() }}
{%- endif %}
{%- endblock %}

{%- block class scoped %}
//@@CLASS {{ cls.name }}
{{ super() }}
{%- endblock %}

{%- block epilogue %}

//@@END_BODY
  {{ code_injections | code_at("end") }}
{%- endblock %}
