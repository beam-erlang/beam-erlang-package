# SPDX-License-Identifier: Apache-2.0
# One source inventory and compilation recipe for standalone and distro builds.
include_guard(GLOBAL)
function(beam_package_modules output)
    set(${output} beam_pkg beam_pkg_util beam_pkg_toml beam_pkg_archive beam_pkg_manifest beam_pkg_build beam_pkg_environment beam_pkg_task beam_pkg_target beam_pkg_export PARENT_SCOPE)
endfunction()

function(beam_package_build TARGET)
    cmake_parse_arguments(PARSE_ARGV 1 PKG "" "OUTPUT_DIRECTORY;DESCRIPTOR_TOOL;RUNTIME_BUILD_ID"
        "COMPILER_COMMAND;COMPILER_DEPENDS")
    if(PKG_UNPARSED_ARGUMENTS OR NOT PKG_OUTPUT_DIRECTORY OR NOT PKG_COMPILER_COMMAND)
        message(FATAL_ERROR "${TARGET}: provide OUTPUT_DIRECTORY and COMPILER_COMMAND")
    endif()
    set(_source_root "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src")
    set(_native_helper "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/BEAMPackageNative.cmake")
    file(SHA256 "${_native_helper}" _native_helper_sha256)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_native_helper}")
    set(_staged_helper "${PKG_OUTPUT_DIRECTORY}/cmake/BEAMPackageNative.cmake")
    add_custom_command(OUTPUT "${_staged_helper}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${PKG_OUTPUT_DIRECTORY}/cmake"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_native_helper}" "${_staged_helper}"
        DEPENDS "${_native_helper}" VERBATIM)
    beam_package_modules(_modules)
    set(_outputs)
    foreach(_module IN LISTS _modules)
        set(_source "${_source_root}/${_module}.erl")
        if(NOT EXISTS "${_source}")
            message(FATAL_ERROR "Incomplete beam-erlang-package sources: ${_source}")
        endif()
        set(_output "${PKG_OUTPUT_DIRECTORY}/ebin/${_module}.beam")
        set(_definitions)
        set(_helper_dependencies)
        if(_module STREQUAL beam_pkg_build)
            list(APPEND _definitions -D "BEAM_PACKAGE_NATIVE_HELPER_SHA256=<<\"${_native_helper_sha256}\">>")
            list(APPEND _helper_dependencies "${_native_helper}")
        endif()
        add_custom_command(OUTPUT "${_output}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${PKG_OUTPUT_DIRECTORY}/ebin"
            COMMAND ${PKG_COMPILER_COMMAND} ${_definitions} -o "${PKG_OUTPUT_DIRECTORY}/ebin" -- "${_source}"
            DEPENDS "${_source}" "${CMAKE_CURRENT_FUNCTION_LIST_FILE}" ${PKG_COMPILER_DEPENDS} ${_helper_dependencies}
            COMMENT "Compiling package command ${_module}" VERBATIM)
        list(APPEND _outputs "${_output}")
    endforeach()
    string(JOIN "\n" _inventory ${_modules})
    file(CONFIGURE OUTPUT "${PKG_OUTPUT_DIRECTORY}/modules.txt"
        CONTENT "${_inventory}\n" NEWLINE_STYLE UNIX @ONLY)
    if(NOT PKG_DESCRIPTOR_TOOL OR NOT PKG_RUNTIME_BUILD_ID)
        message(FATAL_ERROR "${TARGET}: provide DESCRIPTOR_TOOL and RUNTIME_BUILD_ID")
    endif()
    set(_descriptor "${PKG_OUTPUT_DIRECTORY}/application.etf")
    add_custom_command(OUTPUT "${_descriptor}"
        COMMAND "${Python3_EXECUTABLE}" -B "${PKG_DESCRIPTOR_TOOL}" create
            --root "${PKG_OUTPUT_DIRECTORY}" --inventory "${PKG_OUTPUT_DIRECTORY}/modules.txt"
            --entry beam_pkg:command --contract command --name beam-pkg --version 2
            --runtime-build "${PKG_RUNTIME_BUILD_ID}"
            --service output
            --output "${_descriptor}"
        DEPENDS ${_outputs} "${PKG_OUTPUT_DIRECTORY}/modules.txt" "${PKG_DESCRIPTOR_TOOL}"
        VERBATIM)
    add_custom_target(${TARGET} ALL DEPENDS ${_outputs} "${_descriptor}" "${_staged_helper}")
    set_target_properties(${TARGET} PROPERTIES
        BEAM_PACKAGE_MODULES "${_modules}"
        BEAM_PACKAGE_FILES "${_outputs}"
        BEAM_PACKAGE_INVENTORY "${PKG_OUTPUT_DIRECTORY}/modules.txt"
        BEAM_PACKAGE_DESCRIPTOR "${_descriptor}"
        BEAM_PACKAGE_NATIVE_HELPER "${_staged_helper}"
        BEAM_PACKAGE_NATIVE_HELPER_SHA256 "${_native_helper_sha256}")
endfunction()

function(beam_package_install target launcher binding runtime)
    get_target_property(_files "${target}" BEAM_PACKAGE_FILES)
    get_target_property(_inventory "${target}" BEAM_PACKAGE_INVENTORY)
    get_target_property(_descriptor "${target}" BEAM_PACKAGE_DESCRIPTOR)
    get_target_property(_native_helper "${target}" BEAM_PACKAGE_NATIVE_HELPER)
    install(FILES ${_files} DESTINATION lib/beam/apps/beam-pkg/ebin)
    install(FILES "${_inventory}" "${_descriptor}" DESTINATION lib/beam/apps/beam-pkg)
    install(FILES "${_native_helper}" DESTINATION lib/beam/apps/beam-pkg/cmake)
    install(PROGRAMS "${launcher}" DESTINATION bin RENAME "beam-pkg${CMAKE_EXECUTABLE_SUFFIX}")
    set(_sidecar "${CMAKE_CURRENT_BINARY_DIR}/beam-pkg${CMAKE_EXECUTABLE_SUFFIX}.beam-launcher")
    file(GENERATE OUTPUT "${_sidecar}" CONTENT "beam-launcher-v1\n${binding}\n${runtime}\n../lib/beam/apps/beam-pkg/application.etf\n" NEWLINE_STYLE UNIX)
    install(FILES "${_sidecar}" DESTINATION bin)
endfunction()
