# SPDX-License-Identifier: Apache-2.0
# One source inventory and compilation recipe for standalone and distro builds.
include_guard(GLOBAL)

function(beam_package_build TARGET)
    cmake_parse_arguments(PARSE_ARGV 1 PKG "" "OUTPUT_DIRECTORY"
        "COMPILER_COMMAND;COMPILER_DEPENDS")
    if(PKG_UNPARSED_ARGUMENTS OR NOT PKG_OUTPUT_DIRECTORY OR NOT PKG_COMPILER_COMMAND)
        message(FATAL_ERROR "${TARGET}: provide OUTPUT_DIRECTORY and COMPILER_COMMAND")
    endif()
    set(_source_root "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src")
    set(_modules beam_pkg)
    set(_outputs)
    foreach(_module IN LISTS _modules)
        set(_source "${_source_root}/${_module}.erl")
        if(NOT EXISTS "${_source}")
            message(FATAL_ERROR "Incomplete beam-erlang-package sources: ${_source}")
        endif()
        set(_output "${PKG_OUTPUT_DIRECTORY}/ebin/${_module}.beam")
        add_custom_command(OUTPUT "${_output}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${PKG_OUTPUT_DIRECTORY}/ebin"
            COMMAND ${PKG_COMPILER_COMMAND} -o "${PKG_OUTPUT_DIRECTORY}/ebin" -- "${_source}"
            DEPENDS "${_source}" "${CMAKE_CURRENT_FUNCTION_LIST_FILE}" ${PKG_COMPILER_DEPENDS}
            COMMENT "Compiling package command ${_module}" VERBATIM)
        list(APPEND _outputs "${_output}")
    endforeach()
    string(JOIN "\n" _inventory ${_modules})
    file(CONFIGURE OUTPUT "${PKG_OUTPUT_DIRECTORY}/modules.txt"
        CONTENT "${_inventory}\n" @ONLY)
    add_custom_target(${TARGET} DEPENDS ${_outputs})
    set_target_properties(${TARGET} PROPERTIES
        BEAM_PACKAGE_MODULES "${_modules}"
        BEAM_PACKAGE_FILES "${_outputs}"
        BEAM_PACKAGE_INVENTORY "${PKG_OUTPUT_DIRECTORY}/modules.txt")
endfunction()
